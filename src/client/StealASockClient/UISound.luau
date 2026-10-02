-- UISound: every UI sound by name, played locally at the player's Sound effects / Music volume.
-- All ids below are Roblox's own UI sounds and music (creator "Roblox", public domain, free in any
-- experience): the "Roblox GUI - ..." and "Roblox_UI_..." packs from the Creator Store. Swap any of
-- them for another audio id ("rbxassetid://123"); "" makes that sound silent. docs/UI.md lists
-- what each one is for.
local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

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
} :: { [string]: string }

-- per-sound loudness on top of the player's volume (0..1)
local GAIN = { hover = 0.25, coin = 0.45, pop = 0.6, whoosh = 0.55, tab = 0.7, toggle = 0.8, music = 1 } :: { [string]: number }
-- the least time between two plays of the same sound, so 16 flying coins don't become a wall of noise
local MIN_GAP = { coin = 0.07, hover = 0.06, pop = 0.05, click = 0.03, whoosh = 0.1 } :: { [string]: number }

local sfxVolume, musicVolume = 0.8, 0.5
local cache = {} :: { [string]: Sound }
local lastPlayed = {} :: { [string]: number }
local music: Sound? = nil

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

function UISound.SetVolumes(musicVol: number, sfxVol: number)
	musicVolume = math.clamp(musicVol, 0, 1)
	sfxVolume = math.clamp(sfxVol, 0, 1)
	if music then
		music.Volume = musicVolume * 0.5
	end
end

-- Loads every UI sound in the background, so the first click isn't silent while it downloads.
function UISound.Preload()
	local list = {}
	for name in pairs(UISound.Ids) do
		local s = if name == "music" then nil else soundFor(name)
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

-- Starts the background music loop (does nothing while Ids.music is empty).
function UISound.StartMusic()
	if music or UISound.Ids.music == "" then
		return
	end
	local s = Instance.new("Sound")
	s.Name = "UI_music"
	s.SoundId = UISound.Ids.music
	s.Looped = true
	s.Volume = musicVolume * 0.5
	s.Parent = SoundService
	s:Play()
	music = s
end

return UISound
