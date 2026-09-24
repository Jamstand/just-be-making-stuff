-- Audio: every LOCAL sound routes through the two server-created SoundGroups
-- (SoundService.GeodeMusic / GeodeSFX) so the Settings sliders attenuate client
-- and server sounds alike (server Sounds set .SoundGroup themselves). Also owns
-- the background playlist (moved here from Effects.startMusic).
--
--   Audio.Init(Config)                        find the groups (FindFirstChild → WaitForChild 3 s →
--                                             local fallback), start the playlist
--   Audio.Play(id, volume?, speed?, parent?)  one-shot SFX in GeodeSFX; 2D unless parented to a part
--   Audio.Apply({ music = 0..100, sfx = 0..100 })  group volumes (n/100); other keys ignored
--
-- The playlist Sound has Volume 1 — the MUSIC group volume is the only knob, so
-- the slider and the default (Config.Social.SettingsDefault.music, 22) agree.

local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local Audio = {}
local Config
local musicGroup, sfxGroup = nil, nil
local musicVol, sfxVol = 0.22, 1 -- last applied (0..1), re-applied once the groups resolve
local playlistStarted = false

local function defaults()
	local d = Config and Config.Social and Config.Social.SettingsDefault
	return {
		music = math.clamp((d and tonumber(d.music)) or 22, 0, 100),
		sfx = math.clamp((d and tonumber(d.sfx)) or 100, 0, 100),
	}
end

-- FindFirstChild first (server groups replicate before any client script runs in
-- practice), then a bounded wait, then a client-local group so sounds still play
-- against an older server that never created them.
local function resolveGroup(name, volume)
	local g = SoundService:FindFirstChild(name)
	if not (g and g:IsA("SoundGroup")) then
		local w = SoundService:WaitForChild(name, 3)
		g = (w and w:IsA("SoundGroup")) and w or nil
	end
	if not g then
		warn(("[Audio] SoundService.%s missing — using a client-local SoundGroup"):format(name))
		g = Instance.new("SoundGroup")
		g.Name = name
		g.Parent = SoundService
	end
	g.Volume = volume
	return g
end

local function startPlaylist()
	if playlistStarted then return end
	local ids = Config and Config.Music
	if not ids or #ids == 0 then return end
	playlistStarted = true
	task.spawn(function()
		local s = Instance.new("Sound")
		s.Name = "GeodePlaylist"
		s.Volume = 1 -- the group volume is the knob
		s.Looped = false
		if musicGroup then s.SoundGroup = musicGroup end
		s.Parent = SoundService
		local i = math.random(#ids) - 1
		while s.Parent do
			i = (i % #ids) + 1
			s.SoundId = ids[i]
			local t0 = os.clock()
			while not s.IsLoaded and os.clock() - t0 < 8 do task.wait(0.25) end
			if s.IsLoaded and s.TimeLength > 1 then
				s:Play()
				local done = false
				local conn = s.Ended:Connect(function() done = true end)
				local limit = s.TimeLength + 6
				local t1 = os.clock()
				while not done and os.clock() - t1 < limit do task.wait(0.5) end
				conn:Disconnect()
				s:Stop()
				task.wait(1.5)
			else
				task.wait(1) -- track failed to load; move on to the next
			end
		end
	end)
end

function Audio.Init(config)
	Config = config
	local d = defaults()
	musicVol, sfxVol = d.music / 100, d.sfx / 100
	-- resolve off the boot thread: WaitForChild may take up to 3 s on an old server
	task.spawn(function()
		musicGroup = resolveGroup("GeodeMusic", musicVol)
		sfxGroup = resolveGroup("GeodeSFX", sfxVol)
		startPlaylist()
	end)
end

function Audio.Apply(s)
	if type(s) ~= "table" then return end
	local m = tonumber(s.music)
	if m and m == m then
		musicVol = math.clamp(m, 0, 100) / 100
		if musicGroup then musicGroup.Volume = musicVol end
	end
	local f = tonumber(s.sfx)
	if f and f == f then
		sfxVol = math.clamp(f, 0, 100) / 100
		if sfxGroup then sfxGroup.Volume = sfxVol end
	end
end

function Audio.Play(id, volume, speed, parent)
	if type(id) ~= "string" or id == "" then return nil end
	local snd = Instance.new("Sound")
	snd.Name = "GeodeSFXShot" -- never "GeodeSFX": that name is the SoundGroup in SoundService
	snd.SoundId = id
	snd.Volume = volume or 0.5
	snd.PlaybackSpeed = speed or 1
	if sfxGroup then snd.SoundGroup = sfxGroup end
	snd.Parent = parent or SoundService
	snd:Play()
	Debris:AddItem(snd, 6)
	return snd
end

return Audio
