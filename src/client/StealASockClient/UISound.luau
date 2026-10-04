-- UISound: every UI sound by name, played locally at the player's Sound effects / Music volume.
-- All ids below are Roblox's own UI sounds and music (creator "Roblox", public domain, free in any
-- experience): the "Roblox GUI - ..." and "Roblox_UI_..." packs from the Creator Store. Swap any of
-- them for another audio id ("rbxassetid://123"); "" makes that sound silent. docs/UI.md lists
-- what each one is for.
local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local UISound = {}

UISound.Ids = {
	click = "rbxassetid://17208396156", -- any button (Roblox GUI - Select)
	hover = "rbxassetid://17208339919", -- mouse over a button, desktop only, very quiet (Roblox GUI - Hover 01)
	open = "rbxassetid://15675046931", -- a menu panel opens (Roblox_UI_Sweep)
	close = "rbxassetid://17208186900", -- a menu panel closes (Roblox GUI - Back)
	tab = "rbxassetid://17208408337", -- switching tabs inside a panel (Roblox GUI - Tab)
	toggle = "rbxassetid://15675032796", -- a settings switch flips (Roblox_UI_Small_Click)
	buy = "rbxassetid://17208380755", -- cash purchase succeeded, Item Shop (Roblox GUI - Purchase)
	coin = "rbxassetid://17208319162", -- one coin landing in the cash pill, plays a lot (Roblox GUI - Pickup)
	error = "rbxassetid://17208353912", -- can't afford / not allowed (Roblox GUI - Negative)
	success = "rbxassetid://17208361335", -- generic good outcome (Roblox GUI - Notification High)
	confetti = "rbxassetid://15675085146", -- big celebration: pass, milestone, rare drop (Roblox_UI_Indicator)
	newSock = "rbxassetid://17208327798", -- a new Sockdex entry (Roblox GUI - Aura)
	whoosh = "rbxassetid://15675028888", -- banners and toasts sliding in (Roblox_UI_Whoosh_02)
	pop = "rbxassetid://17208204604", -- small pop-ins: badges, cards (Roblox GUI - Bubble)
	sell = "rbxassetid://127645268874265", -- a sock was sold (CoinTransfer_01)
	music = "rbxassetid://15675069601", -- background music loop: calm marimba and glockenspiel (Roblox_UI_Loop_Calm_Music)
	title = "rbxassetid://15930255433", -- the title screen's loop: a bouncy retro flute tune in a major key (Roblox_RetroFluteMusic_01)
} :: { [string]: string }

-- per-sound loudness on top of the player's volume (0..1)
local GAIN = { hover = 0.25, coin = 0.45, pop = 0.6, whoosh = 0.55, tab = 0.7, toggle = 0.8, music = 1, title = 1 } :: { [string]: number }
-- the least time between two plays of the same sound, so 16 flying coins don't become a wall of noise
local MIN_GAP = { coin = 0.07, hover = 0.06, pop = 0.05, click = 0.03, whoosh = 0.1 } :: { [string]: number }

local sfxVolume, musicVolume = 0.8, 0.5
local cache = {} :: { [string]: Sound }
local lastPlayed = {} :: { [string]: number }
local LOOPS = { music = true, title = true } :: { [string]: boolean } -- the music loops (not one-shot sounds)
local FADE = 1.2 -- seconds a crossfade between two loops takes
local loops = {} :: { [string]: Sound } -- the loop Sounds made so far
local wanted = "music" -- the loop that plays (MainMenu asks for "title" while the title screen shows)
local current: string? = nil -- the loop playing now
local started = false -- StartMusic ran (the saved Music volume is known)

local function soundFor(name: string): Sound?
	local id = UISound.Ids[name]
	if not id or id == "" then
		return nil
	end
	local s = cache[name]
	if not s then
		s = Instance.new("Sound")
		s.Name = "UI_" .. name
		s.SoundId = id
		s.Parent = SoundService
		cache[name] = s
	end
	return s
end

-- Plays a UI sound. `pitch` defaults to a tiny random wobble so repeats don't sound robotic.
function UISound.Play(name: string, pitch: number?)
	if sfxVolume <= 0 then
		return
	end
	local now = os.clock()
	if now - (lastPlayed[name] or 0) < (MIN_GAP[name] or 0) then
		return
	end
	local s = soundFor(name)
	if not s then
		return
	end
	lastPlayed[name] = now
	local copy = s:Clone() -- overlapping plays (coins) each get their own copy
	copy.Volume = sfxVolume * (GAIN[name] or 1)
	copy.PlaybackSpeed = pitch or (0.96 + math.random() * 0.08)
	copy.Parent = SoundService
	copy.Ended:Once(function()
		copy:Destroy()
	end)
	Debris:AddItem(copy, 10) -- in case it never loads (and so never ends)
	copy:Play()
end

local function loopVolume(name: string): number
	return musicVolume * 0.5 * (GAIN[name] or 1)
end

function UISound.SetVolumes(musicVol: number, sfxVol: number)
	musicVolume = math.clamp(musicVol, 0, 1)
	sfxVolume = math.clamp(sfxVol, 0, 1)
	local s = current and loops[current]
	if s then
		s.Volume = loopVolume(current :: string)
	end
end

-- Loads every UI sound in the background, so the first click isn't silent while it downloads.
function UISound.Preload()
	local list = {}
	for name in pairs(UISound.Ids) do
		local s = if LOOPS[name] then nil else soundFor(name)
		if s then
			table.insert(list, s)
		end
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(list)
		end)
	end)
end

local function loopSound(name: string): Sound?
	local id = UISound.Ids[name]
	if not id or id == "" then
		return nil
	end
	local s = loops[name]
	if not s then
		s = Instance.new("Sound")
		s.Name = "UI_" .. name
		s.SoundId = id
		s.Looped = true
		s.Volume = 0
		s.Parent = SoundService
		loops[name] = s
	end
	return s
end

-- Fades from the loop playing now to `wanted` (from its start); the old one stops once it's quiet.
local function crossfade(t: number)
	if current == wanted then
		return
	end
	local oldName = current
	local old = oldName and loops[oldName]
	current = wanted
	if old then
		local out = TweenService:Create(old, TweenInfo.new(t, Enum.EasingStyle.Sine), { Volume = 0 })
		out.Completed:Once(function(playbackState)
			-- (unless it was asked for again meanwhile: then its fade-in took over)
			if playbackState == Enum.PlaybackState.Completed and current ~= oldName then
				old:Stop()
			end
		end)
		out:Play()
	end
	local s = loopSound(wanted)
	if s then
		s.Volume = 0
		s.TimePosition = 0
		s:Play()
		TweenService:Create(s, TweenInfo.new(t, Enum.EasingStyle.Sine), { Volume = loopVolume(wanted) }):Play()
	end
end

-- Starts the music: the loop asked for with SetTrack ("music" unless the title screen asked for
-- "title"), fading in. Does nothing for a loop whose id is "".
function UISound.StartMusic()
	if started then
		return
	end
	started = true
	crossfade(0.6)
end

-- Which music loop plays: "music" (the game) or "title" (the title screen). Before StartMusic it
-- only picks the loop StartMusic will play; after, the two crossfade.
function UISound.SetTrack(name: string)
	if not LOOPS[name] then
		return
	end
	wanted = name
	if started then
		crossfade(FADE)
	end
end

return UISound
