-- UISound: every UI sound by name, played locally at the player's Sound effects / Music volume.
-- The ids start empty (silent): paste Roblox audio ids ("rbxassetid://123") into Ids below -
-- docs/UI.md lists what each one is for and a prompt for the local Claude to pick free sounds.
local SoundService = game:GetService("SoundService")

local UISound = {}

UISound.Ids = {
	click = "", -- any button
	hover = "", -- mouse over a button (desktop only, very quiet)
	open = "", -- a menu panel opens
	close = "", -- a menu panel closes
	tab = "", -- switching tabs inside a panel
	toggle = "", -- a settings switch flips
	buy = "", -- cash purchase succeeded (Item Shop)
	coin = "", -- one coin landing in the cash pill (plays a lot: keep it short)
	error = "", -- can't afford / not allowed
	success = "", -- generic good outcome
	confetti = "", -- big celebration (pass bought, milestone, rare drop)
	newSock = "", -- a new Sockdex entry
	whoosh = "", -- banners and toasts sliding in
	pop = "", -- small pop-ins (badges, cards)
	sell = "", -- a sock was sold
	music = "", -- background music loop
} :: { [string]: string }

-- per-sound loudness on top of the player's volume (0..1)
local GAIN = { hover = 0.25, coin = 0.5, pop = 0.6, whoosh = 0.6, music = 1 } :: { [string]: number }

local sfxVolume, musicVolume = 0.8, 0.5
local cache = {} :: { [string]: Sound }
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
	local s = soundFor(name)
	if not s then
		return
	end
	local copy = s:Clone() -- overlapping plays (coins) each get their own copy
	copy.Volume = sfxVolume * (GAIN[name] or 1)
	copy.PlaybackSpeed = pitch or (0.96 + math.random() * 0.08)
	copy.Parent = SoundService
	copy.Ended:Once(function()
		copy:Destroy()
	end)
	copy:Play()
end

function UISound.SetVolumes(musicVol: number, sfxVol: number)
	musicVolume = math.clamp(musicVol, 0, 1)
	sfxVolume = math.clamp(sfxVol, 0, 1)
	if music then
		music.Volume = musicVolume * 0.5
	end
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
