--[[
    Central tuning for Skybrawl. Server and client both require this.

    Units are studs and seconds. Fighters live on a 2D plane: X is
    left/right, Y is up/down, and every arena sits at its own origin.
]]

local Config = {}

Config.GameName = "Skybrawl"

-- Movement ----------------------------------------------------------------

Config.Physics = {
	FighterWidth = 2.4,
	FighterHeight = 5.4,

	Gravity = 150,
	MaxFallSpeed = 62,
	FastFallSpeed = 95,
	FastFallGravityMult = 1.8,

	RunSpeed = 26,
	AirSpeed = 23,
	GroundAccel = 260,
	GroundDecel = 230,
	AirAccel = 150,
	AirDecel = 45,
	-- When knockback pushes you faster than AirSpeed, you keep that
	-- momentum and only bleed it off at this rate.
	OverspeedDecel = 55,

	JumpVelocity = 58,
	AirJumpVelocity = 52,
	MaxAirJumps = 2,
	ShortHopWindow = 0.1,
	ShortHopMult = 0.55,

	DashSpeed = 46,
	DashTime = 0.18,
	DashCooldown = 0.35,

	SpotDodgeTime = 0.36,
	SpotDodgeCooldown = 0.9,
	AirDodgeSpeed = 58,
	AirDodgeTime = 0.22,
	AirDodgeInvuln = 0.3,
	AirDodgeCooldown = 1.6,

	WallSlideSpeed = 9,
	WallJumpX = 30,
	WallJumpY = 54,
	MaxWallJumps = 3,

	DropThroughTime = 0.25,
	LandingLag = 0.08,

	-- Hitstun movement
	HitstunGravityScale = 0.65,
	KnockbackDrag = 0.45, -- exponential decay per second while in hitstun
	DIAccel = 18,
}

-- Combat ------------------------------------------------------------------

Config.Combat = {
	KnockbackScale = 1.3,
	BaseHitstun = 0.24,
	HitstunPerForce = 0.0038,
	MaxHitstun = 0.9,
	MaxDamage = 999,

	ChargeDamageBonus = 0.5, -- fully charged heavies deal +50%
	ChargeKnockbackBonus = 0.25,

	-- Combo flow (Brawlhalla-style)
	-- After one of your attacks hits, for ChaseWindow seconds your next dodge
	-- is a chase dodge: a quick directional burst with no invulnerability that
	-- ignores your dodge cooldown. Light attacks that hit can also be cancelled
	-- into a jump or a chase dodge once their active frames end.
	ChaseWindow = 0.55,
	ChaseDodgeSpeed = 50,
	ChaseDodgeTime = 0.12,
	-- Gravity cancel: an air spot dodge lets you use ground light attacks in
	-- the air while it lasts (and this long after).
	GravityCancelGrace = 0.06,
	-- Hit-stop: attacker and victim freeze briefly when a hit lands.
	HitStopBase = 0.035,
	HitStopPerForce = 0.0009,
	HitStopMax = 0.12,
	-- Hits that land this soon after the victim's hitstun ends still extend
	-- the combo counter (as a string, not a true combo).
	ComboGrace = 0.35,

	RespawnTime = 2.0,
	RespawnInvuln = 2.0,
	KOCreditWindow = 6, -- seconds a hit counts toward KO credit

	-- Server-side validation slack for client hit reports
	HitTimeSlack = 0.6,
	HitRangeSlack = 11,
	DodgeInvulnSlack = 0.08,
	MaxActionsPerSecond = 40,
}

-- Battlegrounds-style combat ------------------------------------------------

Config.Battle = {
	-- Punch chains: a neutral ground light starts a 4-hit chain (three quick
	-- hits, then the weapon's neutral light as a launcher). Press again
	-- within ChainWindow of a chain hit's active frames ending to continue.
	ChainWindow = 0.5,

	-- Block: hold to block hits from the front. Blocked hits do no damage but
	-- drain the guard meter; an empty meter breaks the guard and stuns.
	GuardMax = 100,
	GuardDrainBase = 5,
	GuardDrainPerDamage = 2.2,
	GuardDrainHeavy = 1.6, -- heavies drain this much more
	GuardRegen = 28, -- per second, once GuardRegenDelay has passed since the last blocked hit
	GuardRegenDelay = 1.0,
	BlockStun = 0.14, -- the blocker is held in block this long after a blocked hit
	BlockPushback = 16,
	GuardBreakStun = 1.1,

	-- Ragdoll knockdowns: hits at least this strong send the victim tumbling
	-- limp. Landing while still tumbling knocks them down (invulnerable while
	-- down and getting up) unless they tech: press dodge just before landing
	-- to roll back up.
	RagdollForce = 60,
	TumbleHold = 1.0, -- how long a ragdoll stays limp over the stage after hitstun
	KnockdownTime = 0.75,
	KnockdownMinTime = 0.25, -- earliest a downed fighter can get up by pressing a button
	GetUpTime = 0.3,
	TechWindow = 0.2,
	TechRollTime = 0.36,
	TechRollSpeed = 24,

	-- Ultimate: a meter filled by fighting. Full, it awakens you (everyone
	-- freezes for the cut-in, then you get an aura, more damage and speed)
	-- and gives you one cinematic ultimate move while awake.
	UltMax = 100,
	UltPerDamageDealt = 1.1,
	UltPerDamageTaken = 0.6,
	UltPerBlocked = 0.5,
	AwakenFreeze = 1.1,
	AwakenTime = 20,
	AwakenDamageMult = 1.15,
	AwakenSpeedMult = 1.1,
}

-- Weapons on the stage ----------------------------------------------------

Config.WeaponDrops = {
	FirstSpawnDelay = 2,
	SpawnIntervalMin = 5,
	SpawnIntervalMax = 9,
	MaxOnStage = 3,
	PickupRange = 4.5, -- client
	PickupRangeServer = 8, -- server validation
	FallSpeed = 40,
	Lifetime = 30,

	ThrowSpeed = 85,
	ThrowGravity = 35,
	ThrowLifetime = 1.2,
	ThrowDamage = 6,
	ThrowBaseKnockback = 20,
	ThrowKnockbackScaling = 22,
	ThrowAngle = 35,
	ThrowRecovery = 0.25,
}

-- Matches -----------------------------------------------------------------

Config.Match = {
	MaxArenas = 8,
	ArenaSpacing = 2500,
	ArenaHeight = 300,
	CountdownSeconds = 3,
	ResultsSeconds = 9,
	LoadTimeout = 10,
	DefaultStocks = 3,
	DefaultTimeLimit = 480, -- stock matches still end after this long
	DefaultTimedLength = 180,
	SuddenDeathDamage = 0, -- unused hook for future sudden death
}

Config.Modes = {
	["1v1"] = { Label = "1v1", MaxPlayers = 2, Teams = true, TeamSize = 1 },
	["2v2"] = { Label = "2v2", MaxPlayers = 4, Teams = true, TeamSize = 2 },
	FFA = { Label = "Free-for-all", MaxPlayers = 4, Teams = false },
}

Config.TeamColors = {
	[1] = Color3.fromRGB(235, 84, 84),
	[2] = Color3.fromRGB(70, 140, 245),
	[3] = Color3.fromRGB(90, 205, 110),
	[4] = Color3.fromRGB(245, 200, 60),
}

-- Matchmaking -------------------------------------------------------------

Config.Queue = {
	TickSeconds = 1,
	RatingWindowStart = 100,
	RatingWindowGrowth = 20, -- per second waited
	RatingWindowMax = 800,
	AnyoneAfterSeconds = 45,
	FFAStartAfterSeconds = 20, -- start an FFA with 2-3 people after this
	FFAFillWithBots = true,
	FFAFillDifficulty = "Normal",
	MapPools = {
		["1v1"] = { "SkyShip", "FrozenPeaks", "JungleTemple", "SkyholdKeep", "AncientRuins", "DuelRock" },
		["2v2"] = { "SkyShip", "VolcanicForge", "JungleTemple", "SkyholdKeep", "TwinIsles", "AncientRuins" },
		FFA = { "SkyShip", "VolcanicForge", "FrozenPeaks", "JungleTemple", "SkyholdKeep", "TwinIsles", "AncientRuins" },
	},
}

Config.Rooms = {
	MaxRooms = 40,
	CodeLength = 6,
	NameMaxLength = 28,
	StocksMin = 1,
	StocksMax = 9,
	TimeMin = 60,
	TimeMax = 900,
	DamageMultMin = 0.5,
	DamageMultMax = 3,
	FriendCacheSeconds = 60,
}

-- Bots --------------------------------------------------------------------

Config.Bots = {
	Names = {
		"Garnet",
		"Basil",
		"Pip",
		"Rook",
		"Moss",
		"Juniper",
		"Flint",
		"Sable",
		"Wren",
		"Bramble",
		"Cobalt",
		"Thistle",
		"Ember",
		"Quill",
		"Onyx",
		"Fern",
	},
	Difficulties = {
		Easy = {
			Reaction = 0.45,
			Aggression = 0.45,
			DodgeChance = 0.06,
			HeavyChance = 0.2,
			Recovery = 0.7,
			Accuracy = 0.55,
			BlockChance = 0.08,
			TechChance = 0.2,
		},
		Normal = {
			Reaction = 0.26,
			Aggression = 0.7,
			DodgeChance = 0.22,
			HeavyChance = 0.35,
			Recovery = 0.9,
			Accuracy = 0.8,
			BlockChance = 0.25,
			TechChance = 0.55,
		},
		Hard = {
			Reaction = 0.13,
			Aggression = 0.9,
			DodgeChance = 0.45,
			HeavyChance = 0.5,
			Recovery = 1.0,
			Accuracy = 0.95,
			BlockChance = 0.4,
			TechChance = 0.85,
		},
	},
	DifficultyOrder = { "Easy", "Normal", "Hard" },
}

-- Progression -------------------------------------------------------------

Config.Ranked = {
	StartRating = 1000,
	PlacementMatches = 10,
	KPlacement = 40,
	K = 24,
	MinRating = 200,
	Tiers = {
		{ Name = "Tin", Min = 0, Color = Color3.fromRGB(150, 150, 160) },
		{ Name = "Bronze", Min = 910, Color = Color3.fromRGB(205, 127, 50) },
		{ Name = "Silver", Min = 1130, Color = Color3.fromRGB(200, 205, 215) },
		{ Name = "Gold", Min = 1390, Color = Color3.fromRGB(255, 205, 60) },
		{ Name = "Platinum", Min = 1680, Color = Color3.fromRGB(110, 225, 220) },
		{ Name = "Diamond", Min = 2000, Color = Color3.fromRGB(150, 170, 255) },
	},
}

Config.Rewards = {
	-- Base amounts for one match, before the source multiplier.
	Coins = { Played = 20, PerKO = 8, Win = 30, MaxPerMatch = 150 },
	XP = { Played = 40, PerKO = 15, Win = 50, PerDamage = 0.1, MaxPerMatch = 400 },
	SourceMultiplier = {
		Ranked = 1.0,
		Casual = 1.0,
		Custom = 0.5,
		Bots = 0.4,
	},
	-- Custom rooms with any bot in them pay out like bot matches.
	MinMatchSecondsForRewards = 20,
}

Config.Levels = {
	BaseXP = 120,
	PerLevelXP = 60,
	MaxLevel = 200,
}

-- Saving ------------------------------------------------------------------

Config.Data = {
	StoreName = "SkybrawlProfiles_v1",
	LeaderboardStore = "SkybrawlRating1v1_v1",
	AutosaveSeconds = 90,
	LeaderboardRefreshSeconds = 120,
	LeaderboardSize = 10,
}

-- Camera ------------------------------------------------------------------

-- Art --------------------------------------------------------------------
--[[
    Imported art (see art/IMPORTING.md). Everything has a code-built fallback,
    so the game runs before anything is imported.
      ReplicatedStorage.FighterModels.<Legend>   fighter meshes
      ReplicatedStorage.WeaponMeshes.<Id>        weapon meshes ("KestrelSword", "Sword", ...)
      ReplicatedStorage.MapModels.<MapId>        map kits
]]
Config.Art = {
	FighterHeight = 5.6, -- legend rigs are scaled to this (the hurtbox is 5.4)
	OutlineColor = Color3.fromRGB(18, 16, 26),
	OutlineThickness = 0, -- Highlight outlines have a fixed width; 0 = default
	Outlines = false, -- a thin dark Highlight outline around each fighter (classic avatars have none)
	-- Painted backgrounds, drawn by the client's SkyBackdrop as layers far
	-- behind the stage, back to front. Depth is studs behind the fighters'
	-- lane (all behind the maps' 3D scenery, which reaches about 230);
	-- Parallax is how fast a layer scrolls compared with the stage.
	SkyLayers = {
		{ Name = "Sky", Depth = 420, Parallax = 0.03 }, -- far sky, opaque
		{ Name = "Landmarks", Depth = 360, Parallax = 0.09 }, -- distant vista, transparent
		{ Name = "Haze", Depth = 300, Parallax = 0.2 }, -- near clouds/haze, transparent
	},
	-- The server's plain gradient sky, behind everything.
	SkyGradientDepth = 480,
	-- Each map's layer images. Upload art/export/skies/painted/<MapId>_<Layer>.png
	-- as Decals and paste the image ids here (just the number, or
	-- rbxassetid://123). A layer left "" is skipped.
	SkyImages = {
		SkyShip = { Sky = "", Landmarks = "", Haze = "" },
		VolcanicForge = { Sky = "", Landmarks = "", Haze = "" },
		FrozenPeaks = { Sky = "", Landmarks = "", Haze = "" },
		JungleTemple = { Sky = "", Landmarks = "", Haze = "" },
	},
}

Config.Camera = {
	Modes = {
		{ Id = "FrameAll", Label = "Frame All", Description = "Pans and zooms to keep every fighter on screen." },
		{ Id = "FollowMe", Label = "Follow Me", Description = "Stays centered on your fighter." },
		{ Id = "Lookahead", Label = "Lookahead", Description = "Follows you, leaning toward where you're heading." },
		{ Id = "DuelFocus", Label = "Duel Focus", Description = "Frames you and your nearest opponent." },
		{ Id = "FixedStage", Label = "Fixed Stage", Description = "Never moves; the whole arena is always visible." },
	},
	Looks = {
		{
			Id = "Flat",
			Label = "Flat 2D",
			Description = "Far away, narrow lens. Almost no depth.",
			FOV = 14,
			Pitch = 0,
		},
		{
			Id = "Classic",
			Label = "2.5D",
			Description = "A normal lens, so platforms show their depth.",
			FOV = 40,
			Pitch = 0,
		},
		{
			Id = "Tilted",
			Label = "Tilted 2.5D",
			Description = "Slightly above the stage, looking down.",
			FOV = 34,
			Pitch = 12,
		},
		{ Id = "Wide", Label = "Wide 2.5D", Description = "Wide lens with strong perspective.", FOV = 62, Pitch = 4 },
	},
	MinViewHeight = 34,
	FollowViewHeight = 46,
	FramePadding = 14,
	ShakeMax = 2.2,
}

-- Player settings ---------------------------------------------------------

Config.DefaultKeybinds = {
	Keyboard = {
		Left = { "A", "Left" },
		Right = { "D", "Right" },
		Up = { "W", "Up" },
		Down = { "S", "Down" },
		Jump = { "Space" },
		Light = { "J" },
		Heavy = { "K" },
		Dodge = { "L", "LeftShift" },
		Throw = { "H" },
		Block = { "F" },
		Ultimate = { "G" },
	},
	Gamepad = {
		Jump = { "ButtonA" },
		Light = { "ButtonX" },
		Heavy = { "ButtonB" },
		Dodge = { "ButtonR2", "ButtonL2" },
		Throw = { "ButtonY" },
		Block = { "ButtonL1" },
		Ultimate = { "ButtonR1" },
	},
}

Config.InputActions = { "Left", "Right", "Up", "Down", "Jump", "Light", "Heavy", "Dodge", "Throw", "Block", "Ultimate" }
Config.InputBufferTime = 0.12

Config.DefaultSettings = {
	CameraMode = "FrameAll",
	CameraLook = "Flat",
	CameraZoom = 1.0,
	CameraSmoothing = 0.5,
	ScreenShake = true,
	Effects = "Full", -- Full / Reduced / Off: impact frames, debris, auras...
	Cinematics = true, -- camera cut-ins for awakenings and ultimates
	DamageNumbers = true,
	TapJump = true,
	MouseAttacks = true,
	MobileButtonScale = 1.0,
	SfxVolume = 0.7,
	ShowHitboxes = false,
	FightAsAvatar = false, -- your own avatar's look with your legend's moves (read when a match starts)
	Keybinds = Config.DefaultKeybinds,
}

-- Sounds (built-in engine sounds; swap for your own asset IDs) -------------

Config.Sounds = {
	Swing = "rbxasset://sounds/swordslash.wav",
	HeavySwing = "rbxasset://sounds/swordlunge.wav",
	Hit = "rbxasset://sounds/swordlunge.wav",
	Pickup = "rbxasset://sounds/unsheath.wav",
	Jump = "rbxasset://sounds/action_jump.mp3",
	Land = "rbxasset://sounds/action_jump_land.mp3",
	KO = "rbxasset://sounds/swordlunge.wav",
}

return Config
