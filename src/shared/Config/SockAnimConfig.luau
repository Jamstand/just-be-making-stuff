--!strict
-- SockAnimConfig: every tuning knob of the sock animation system (StealASockClient.SockAnim).
-- Numbers only - the moves themselves are code in SockAnim.luau, looked up by the names used here.
-- docs/ANIMATION.md explains the layers, every personality and what to check in Studio.
--
-- Units: angles in radians, offsets in "sock units" (1 = one Blender unit of the sock kit; a
-- normal sock's leg is 4.2 units tall; SockAnim converts to studs with the model's own scale),
-- times in seconds, ranges in studs.

-- One personality per sock type (SockConfig ids). The move names are SockAnim's IDLES / HANGS /
-- CLIPS tables; an unknown name falls back to a calm default (and SockAnim warns once).
export type Personality = {
	idle: string, -- the loop it plays standing in a drawer (and in the menus)
	tempo: number, -- speed of that loop (1 = as designed)
	amp: number, -- size of that loop (1 = as designed)
	fidgets: { string }, -- little one-shots picked at random every few seconds
	showoff: string, -- its signature show-off (rarer socks also mix in Rarity[...].flair)
	hang: string, -- how it hangs, kicks and wiggles on the clothesline
	look: number, -- how much it turns to look at nearby players (0 = never, 1 = fully)
	voice: number, -- pitch of its sounds (PlaybackSpeed multiplier)
	bend: number?, -- most a leg joint may bend (radians); default Limits.Bend / BendSingle
	hatTilt: number?, -- most its Hat bone may tilt (radians); default Limits.HatTilt
	blurb: string, -- one line for docs/ANIMATION.md
}

-- Rarity = energy and flair. Commons are calm and simple; rarer socks move more, fidget more often
-- and show off now and then (with a sparkle in the rarity colour).
export type RarityEnergy = {
	energy: number, -- amplitude multiplier for everything the sock does
	tempo: number, -- speed multiplier for its idle loop
	fidgetEvery: { number }, -- {min, max} seconds between fidgets
	showEvery: { number }?, -- {min, max} seconds between show-offs; nil = never on its own
	flair: { string }, -- generic show-off moves this rarity may do instead of the signature one
	flairChance: number, -- chance (0..1) a show-off is a flair move
	sparkle: number, -- sparkle particles per show-off (0 = none)
}

-- Mutation flavour: one extra motion layer on top of the personality.
export type MutationFlavour = {
	style: string, -- "wobble" | "jitter" | "float" | "flutter" | "proud" | "groove" | "orbit"
	amp: number, -- size of the layer
	freq: number, -- speed of the layer (rad/s of its main wave)
	every: { number }?, -- {min, max} seconds between its extra bursts (Static zaps, Golden chin lifts)
	bpm: number?, -- Rainbow: groove tempo (every Rainbow sock grooves on the same beat)
	lift: number?, -- Glow: float height (sock units)
	radius: number?, -- Lint Galaxy: orbit radius (sock units)
}

export type SoundSpec = {
	id: string, -- "rbxassetid://..." (Roblox-made, public domain) or "" = silent
	volume: number, -- 0..1, times the player's Sound effects setting
	pitch: number, -- PlaybackSpeed (times the personality's voice)
	gap: number, -- least seconds between two plays of this sound by the same sock
}

local SockAnimConfig = {
	-- How the black toon outline is drawn on mesh socks while they bend:
	--   "hull"      the Blender kit's inside-out `_Outline` mesh (skinned to the same bones, so it
	--               bends with the body - the default)
	--   "highlight" hides every `_Outline` MeshPart and gives mesh socks the same Highlight outline
	--               as Part-built socks (SockFX, nearest 22 / 8 with Low graphics). Use it if the hull
	--               tears or lags behind the body in Studio. (ViewportFrames can't draw Highlights,
	--               so menu socks then show without an outline.)
	OutlineMode = "hull",

	Perf = {
		BoneRange = 120, -- bones are driven only this close to the camera (whole-body motion beyond)
		HalfRateRange = 60, -- beyond this the bones update every other frame
		LowGraphicsBoneRange = 50, -- with Low graphics on
		MaxBoneSocks = 40, -- more socks than this bending at once: the bone range shrinks until it fits
		FarRange = 250, -- beyond this whole-body motion updates every 4th frame
		LandDelay = 0.8, -- seconds after PlacedAt before the client moves a drawer sock (the server's buy hop)
		UIFullRate = 8, -- more menu socks than this on screen: they update every other frame
		ZzzRange = 70, -- "Zzz" bubbles only on sleeping socks this close to the camera
	},

	-- Reduce motion: everything this much smaller, no spins / flips / glitch jumps.
	ReduceMotionScale = 0.5,

	-- How far the skin may bend before it creases (from the rig's own tests, SockRigConfig.luau).
	-- Per joint, radians. Twist beyond Twist turns the whole sock instead; half of any bend beyond
	-- Bend tilts the whole sock.
	Limits = {
		Bend = 0.26, -- 15 deg: tested clean on every footed sock
		BendSingle = 0.17, -- 10 deg: Socktopus / The Lost Sock bend through a wide sack
		Twist = 0.17, -- 10 deg about a bone's own axis (Argylo's diamonds flicker past ~20)
		HatTilt = 0.45, -- a hat on the head (a tight helm or wreath: Personality.hatTilt)
		Tentacle = 0.45, -- per tentacle segment
		JawTurn = 0.4, -- share of the rig's `turn` a full jaw-open uses (the rest is `slide`)
	},

	Reactions = {
		ScanEvery = 0.15, -- seconds between each sock's look-around for nearby players
		LookRange = 30, -- turns its upper body toward the nearest player this close
		LookMaxYaw = 1.0, -- radians it can turn its upper body
		LookMaxPitch = 0.4, -- radians it can tip up / down to meet your eyes
		LookSpeed = 4, -- how quickly it turns (higher = snappier)
		NoticeHop = 0.18, -- the little "oh, hi!" hop when someone new comes into view (sock units)
		PerkRange = 16, -- clothesline socks perk up and kick toward a player this close (who could buy them)
		PanicLean = 0.35, -- your socks lean this far away from a thief inside your drawer
		PanicShiver = 0.06, -- and shiver this much
		PanicFlailEvery = { 1.2, 2.6 }, -- {min, max} seconds between panic flails
		FlinchRange = 25, -- socks this close to a Towel Snap flinch
		CheerFromRank = 4, -- a sock of this rarity rank or higher bought / stolen anywhere: socks cheer
		CheerRange = 120, -- socks this close to the camera join the cheer
		CheerDelay = 0.5, -- each one starts up to this much later (a ripple, not a chorus line)
		SleepRange = 40, -- nobody this close ...
		SleepAfter = 45, -- ... for this long: the sock dozes off (drawer socks only)
		PairTurn = 0.6, -- paired socks in one drawer turn this far toward each other
		PairBopBpm = 96, -- and bop together on this beat
		CarryReach = 0.5, -- a carried sock bends this far back toward its home drawer
		CarryFlail = 0.22, -- and flails this much
	},

	-- Positional sounds in the sock's root part, only for socks near you. All Roblox's own audio
	-- (creator "Roblox", IsPublicDomain = true, checked 2026-10-03 on economy.roblox.com).
	Sounds = {
		boing = { id = "rbxassetid://12222124", volume = 0.3, pitch = 1, gap = 0.4 }, -- hops (Short spring sound.wav)
		squeak = { id = "rbxassetid://106557401612525", volume = 0.25, pitch = 1.45, gap = 0.9 }, -- panic, sped-up chirps (BirdHello_03)
		chirp = { id = "rbxassetid://99631809815420", volume = 0.3, pitch = 1.1, gap = 1 }, -- paired (BirdHello_02)
		snore = { id = "rbxassetid://15675062723", volume = 0.14, pitch = 0.7, gap = 3 }, -- sleepy exhale (Roblox_UI_Whistle_Low, slowed)
		cheer = { id = "rbxassetid://12222253", volume = 0.2, pitch = 1, gap = 2 }, -- cheer (victory.wav)
		goodbye = { id = "rbxassetid://15675081158", volume = 0.4, pitch = 1, gap = 1 }, -- sold (Roblox_UI_Cute_Goodbye)
		poof = { id = "rbxassetid://15675055424", volume = 0.3, pitch = 1.1, gap = 1 }, -- the goodbye poof (Roblox_UI_Cute_Pop)
		whoosh = { id = "rbxassetid://12222200", volume = 0.2, pitch = 1, gap = 0.5 }, -- spins and flips (swoosh.wav)
		oof = { id = "rbxassetid://79348298352567", volume = 0.18, pitch = 1.2, gap = 1.5 }, -- flinch at a Towel Snap (Official OOF Sound Effect)
		zap = { id = "", volume = 0.2, pitch = 1, gap = 1 }, -- Static zaps: silent (no Roblox-made zap fits)
	} :: { [string]: SoundSpec },
	SoundRange = 45, -- only socks this close to the camera make sounds
	SoundRollOff = { 6, 45 }, -- {min, max} RollOff distance of every sock sound
	SoundsPerSecond = 6, -- all socks together never play more than this many sounds a second

	Rarity = {} :: { [string]: RarityEnergy },
	Mutations = {} :: { [string]: MutationFlavour },
	Personalities = {} :: { [string]: Personality },
	-- a sock type missing from Personalities
	Default = { idle = "mope", tempo = 1, amp = 0.8, fidgets = { "wiggle" }, showoff = "spin", hang = "kick", look = 0.6, voice = 1, blurb = "a sock with no personality yet" } :: Personality,
}

SockAnimConfig.Rarity = {
	Common    = { energy = 0.75, tempo = 0.9,  fidgetEvery = { 7, 13 }, showEvery = nil,        flair = {},                          flairChance = 0,   sparkle = 0 },
	Rare      = { energy = 0.9,  tempo = 0.95, fidgetEvery = { 6, 11 }, showEvery = { 40, 70 }, flair = {},                          flairChance = 0,   sparkle = 0 },
	Epic      = { energy = 1,    tempo = 1,    fidgetEvery = { 5, 10 }, showEvery = { 30, 50 }, flair = { "spin" },                  flairChance = 0.3, sparkle = 8 },
	Legendary = { energy = 1.1,  tempo = 1.05, fidgetEvery = { 5, 9 },  showEvery = { 22, 38 }, flair = { "spin", "pose" },          flairChance = 0.4, sparkle = 12 },
	Mythic    = { energy = 1.2,  tempo = 1.1,  fidgetEvery = { 4, 8 },  showEvery = { 18, 30 }, flair = { "spin", "flip", "pose" },  flairChance = 0.45, sparkle = 16 },
	SockGod   = { energy = 1.3,  tempo = 1.1,  fidgetEvery = { 4, 7 },  showEvery = { 14, 24 }, flair = { "spin", "flip", "pose" },  flairChance = 0.5, sparkle = 24 },
	-- Secret socks don't spin for you: they glitch, stare and flicker
	Secret    = { energy = 1.1,  tempo = 0.9,  fidgetEvery = { 4, 8 },  showEvery = { 16, 28 }, flair = { "glitch", "stare", "phase" }, flairChance = 0.6, sparkle = 14 },
}

SockAnimConfig.Mutations = {
	Fuzzy        = { style = "wobble",  amp = 1,   freq = 2.6 }, -- soft jelly wobble up the leg
	Static       = { style = "jitter",  amp = 1,   freq = 60, every = { 4, 8 } }, -- buzzing + a zap now and then
	Glow         = { style = "float",   amp = 1,   freq = 1.1, lift = 0.18 }, -- floats a little and breathes
	Holey        = { style = "flutter", amp = 1,   freq = 12 }, -- drafty: the cuff flutters in gusts
	GoldenThread = { style = "proud",   amp = 1,   freq = 0.5, every = { 6, 12 } }, -- chest out, chin lifts
	Rainbow      = { style = "groove",  amp = 1,   freq = 1, bpm = 110 }, -- grooves on a shared beat
	LintGalaxy   = { style = "orbit",   amp = 1,   freq = 0.9, radius = 0.12 }, -- a slow cosmic orbit
}

SockAnimConfig.Personalities = {
	-- Common
	Tubolino      = { idle = "mope",      tempo = 0.8, amp = 1,   fidgets = { "sigh", "droop", "sigh" },          showoff = "mopespin",    hang = "limp",      look = 0.5, voice = 0.85, blurb = "Mopey sway with a droopy cuff; big sighs; a reluctant, sighing spin" },
	AnkleBiter    = { idle = "chomp",     tempo = 1,   amp = 1,   fidgets = { "chomp", "lunge", "wiggle" },       showoff = "chompspin",   hang = "kick",      look = 1,   voice = 1.3,  blurb = "Bouncy little chomper: snaps its top, lunges playfully, spins chomping" },
	CrustyCrew    = { idle = "stiff",     tempo = 1,   amp = 1,   fidgets = { "creak", "creakturn" },             showoff = "stiffbow",    hang = "stiff",     look = 0.4, voice = 0.75, blurb = "Dried rigid: moves in creaky steps, bends only at the ankle, stiff bows" },
	GymGary       = { idle = "pump",      tempo = 1,   amp = 1,   fidgets = { "flex", "squats", "wipe" },         showoff = "flex",        hang = "kick",      look = 0.7, voice = 0.9,  blurb = "Bounces on the spot, flexes, does squats, wipes his brow" },
	-- Rare
	Argylo        = { idle = "posh",      tempo = 1,   amp = 1,   fidgets = { "monocle", "nod", "lookaround" },   showoff = "bow",         hang = "posh",      look = 1,   voice = 0.9,  blurb = "Posh and upright, slow nods, adjusts his monocle, bows to players" },
	ToeToe        = { idle = "wiggle",    tempo = 1,   amp = 1,   fidgets = { "toewiggle", "tiptoe", "wiggle" },  showoff = "tiptoe",      hang = "kick",      look = 0.8, voice = 1.2,  blurb = "Wiggles its five toes non-stop, tip-toe dances" },
	Sockrates     = { idle = "ponder",    tempo = 0.8, amp = 1,   fidgets = { "ponder", "nod", "nod" },           showoff = "eureka",      hang = "ponder",    look = 0.6, voice = 0.85, bend = 0.15, hatTilt = 0.14, blurb = "Slow thoughtful nods and head tilts; a 'eureka!' hop" },
	KneeHigh      = { idle = "noodle",    tempo = 1,   amp = 1,   fidgets = { "noodlewave", "wiggle", "lookaround" }, showoff = "noodlewave", hang = "noodle",  look = 0.8, voice = 0.95, blurb = "Long noodle: waves ripple up the whole leg" },
	-- Epic
	Slipperino    = { idle = "skate",     tempo = 1,   amp = 1,   fidgets = { "glide", "wiggle" },                showoff = "skatespin",   hang = "skate",     look = 0.7, voice = 1.1,  blurb = "Skates side to side leaning into the glide; ice-skater spins" },
	Compressio    = { idle = "tense",     tempo = 1,   amp = 1,   fidgets = { "crunch", "shiverburst" },          showoff = "crunchpop",   hang = "jitter",    look = 0.5, voice = 1.05, blurb = "Tense shivers, scrunches up tight, then pops" },
	Sockhopper    = { idle = "pogo",      tempo = 1,   amp = 1,   fidgets = { "doublebounce", "lookaround" },     showoff = "pogoflip",    hang = "bounce",    look = 0.6, voice = 1,    blurb = "Never stops pogoing; big bounces and pogo flips" },
	DJDryer       = { idle = "bop",       tempo = 1,   amp = 1,   fidgets = { "scratch", "headbang" },            showoff = "scratchspin", hang = "groove",    look = 0.5, voice = 1,    blurb = "Bops to a 120 BPM beat, scratches with its cuff, spins on the drop" },
	-- Legendary
	Socktopus     = { idle = "swim",      tempo = 1,   amp = 1,   fidgets = { "swimstroke", "wiggle", "lookaround" }, showoff = "swirl",     hang = "tentacles", look = 0.7, voice = 1.1,  blurb = "Tentacles wave like swimming while it bobs; a swirling tentacle twirl" },
	Sockington    = { idle = "attention", tempo = 1,   amp = 1,   fidgets = { "salute", "march" },                showoff = "salute",      hang = "stiff",     look = 0.7, voice = 0.85, bend = 0.15, hatTilt = 0.14, blurb = "Stands to attention, salutes, marches in place" },
	Stinkolino    = { idle = "slouch",    tempo = 0.8, amp = 1,   fidgets = { "waft", "slouch", "yawn" },         showoff = "waft",        hang = "limp",      look = 0.4, voice = 0.8,  blurb = "Lazy slouch, yawns, proudly wafts its stink around" },
	-- Mythic
	SockNess      = { idle = "serpent",   tempo = 0.9, amp = 1,   fidgets = { "lookaround", "dip" },              showoff = "rise",        hang = "serpent",   look = 0.9, voice = 0.8,  blurb = "Slow serpent sways of the long neck; looks all around; rises up tall" },
	Shockini      = { idle = "jitter",    tempo = 1,   amp = 1,   fidgets = { "jolt", "jolt", "shiverburst" },    showoff = "overload",    hang = "jitter",    look = 0.6, voice = 1.15, blurb = "Can't keep still: jitters, electric jolts, a full overload" },
	-- Sock God
	Lintlord      = { idle = "regal",     tempo = 0.9, amp = 1,   fidgets = { "toeraise", "nod", "lookaround" },  showoff = "decree",      hang = "posh",      look = 0.8, voice = 0.8,  blurb = "Regal sway, chin up; raises its toe to command the room" },
	Zillionaire   = { idle = "strut",     tempo = 1,   amp = 1,   fidgets = { "hattip", "lookaround" },           showoff = "hattip",      hang = "posh",      look = 0.9, voice = 0.9,  blurb = "Struts on the spot, tips his top hat, twirls" },
	-- Secret
	LostSock      = { idle = "haunt",     tempo = 1,   amp = 1,   fidgets = { "glitch", "stare" },                showoff = "phase",       hang = "float",     look = 0.3, voice = 0.7,  blurb = "Eerie float and slow turn, stares at you, glitchy twitches" },
	PuppetSupreme = { idle = "talk",      tempo = 1,   amp = 1,   fidgets = { "chatter", "gesture", "yawn" },     showoff = "monologue",   hang = "bounce",    look = 1,   voice = 1.2,  blurb = "Never stops talking: jaw flaps, big gestures, a dramatic monologue" },
}

return SockAnimConfig
