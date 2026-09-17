-- JamPure Now Playing — a now-playing dash card for the car.
-- Source A is the Windows media session (ac.currentlyPlaying): whatever Spotify, a browser or a
-- desktop player reports to Windows. Source B is the widget server's Spotify proxy
-- (GET <baseUrl>/now-playing), polled only while A has nothing to show. Track position is
-- interpolated locally between updates with os.preciseClock so the bar moves smoothly, even
-- while the sim is paused (real time keeps flowing, the music keeps playing).
-- Target: CSP 0.2.11+ / 0.3.0 previews. Single file, no requires; the only global is `script`.

script = script or {}

-- ---------------------------------------------------------------- settings (persistent, edited in windowSettings)
local cfg = ac.storage{
  useServer = true,                    -- fall back to the widget server when Windows reports nothing
  baseUrl = 'http://localhost:3000',   -- widget server base URL (no trailing slash needed)
  pollSeconds = 5,                     -- server poll interval, seconds
  compact = false,                     -- single line "title — artist", no eyebrow, no bar
}

-- ---------------------------------------------------------------- constants
local BAR_H = 4                 -- progress bar thickness, px
local GAP_EYEBROW = 2           -- gap under the eyebrow
local GAP_ROW = 1               -- gap between title and artist
local GAP_BAR = 4               -- minimum gap between the artist row and the bar row
local TIMES_GAP = 8             -- gap between the bar and the "m:ss / m:ss" text
local MIN_BAR_W = 24            -- below this the times text is dropped and the bar takes the full width
local RESYNC_S = 1.5            -- re-anchor the interpolated position when the source disagrees by more than this
local REQUEST_TIMEOUT_S = 30    -- safety: clear a stuck inFlight flag after this long
local ELLIPSIS = '…'
local DASH = ' — '

local BG = rgbm(0, 0, 0, 0.55)
local C_TEXT = rgbm(1, 1, 1, 0.96)         -- title
local C_ARTIST = rgbm(0.86, 0.88, 0.92, 1) -- artist
local C_DIM = rgbm(0.62, 0.66, 0.72, 1)    -- eyebrow, times
local C_MUTED = rgbm(0.5, 0.5, 0.55, 0.8)  -- "nothing playing"
local C_TRACK = rgbm(1, 1, 1, 0.16)        -- bar track
local C_FILL = rgbm(0.30, 0.87, 0.50, 1)   -- bar fill

-- Windows media session source ids look like "Spotify.exe" or "SpotifyAB.SpotifyMusic_...!Spotify".
-- Matched case-insensitively as plain substrings, first hit wins; anything unknown is "Windows".
local SOURCE_PATTERNS = {
  { 'spotify', 'Spotify' }, { 'chrome', 'Chrome' }, { 'firefox', 'Firefox' }, { '308046b0af4a39cb', 'Firefox' },
  { 'msedge', 'Edge' }, { 'zunemusic', 'Groove' }, { 'applemusic', 'Apple Music' }, { 'itunes', 'iTunes' },
  { 'tidal', 'TIDAL' }, { 'vlc', 'VLC' }, { 'foobar', 'foobar2000' }, { 'musicbee', 'MusicBee' },
  { 'deezer', 'Deezer' }, { 'amazon', 'Amazon Music' }, { 'youtube', 'YouTube Music' }, { 'soundcloud', 'SoundCloud' },
  { 'winamp', 'Winamp' }, { 'aimp', 'AIMP' }, { 'opera', 'Opera' }, { 'brave', 'Brave' }, { 'vivaldi', 'Vivaldi' },
}

-- ---------------------------------------------------------------- state
-- What the panel shows this frame. Filled by update() from source A or B; strings are kept stable
-- between frames so the fit/format caches below only rebuild when something actually changes.
local cur = {
  playing = false, mode = 'none',   -- mode: 'windows' | 'server' | 'none'
  title = '', artist = '', album = '', source = '',
  pos = -1, dur = -1, frac = 0,     -- seconds; -1 unknown
}

-- Source B (server) last response, in seconds, plus the poll bookkeeping.
local srv = { playing = false, title = '', artist = '', album = '', id = '', dur = -1, progress = -1, err = false }
local inFlight = false
local lastPollAt = -1e9
local lastUrlBase, pollUrl = nil, ''

-- Position anchors: raw = last value the source reported, pos/at = value and clock we interpolate from.
local anchorWin = { raw = -1, pos = -1, at = 0 }
local anchorSrv = { raw = -1, pos = -1, at = 0 }
local lastWinTitle, lastSrvId = nil, nil

-- Caches (rebuilt only when their inputs change; see fitText / times / eyebrow / compact).
local fitTitle = { src = nil, w = -1, str = '' }
local fitArtist = { src = nil, w = -1, str = '' }
local fitCompact = { src = nil, w = -1, str = '' }
local fitNothing = { src = nil, w = -1, str = '' }       -- measured in ui.Font.Title (card)
local fitNothingLine = { src = nil, w = -1, str = '' }   -- measured in ui.Font.Main (compact line)
local timesPosKey, timesDurKey, timesStr, timesW, timesDirty = nil, nil, '', 0, true
local eyebrowKey, eyebrowStr = nil, 'NOW PLAYING'
local compactTitle, compactArtist, compactStr = nil, nil, ''
local srcIdKey, srcLabel = nil, 'Windows'
local fontScale, hSmall, hMain, hTitle = -1, 14, 16, 22
local bgSet = false

-- scratch vectors reused every frame so drawing does not allocate
local p1, p2 = vec2(), vec2()

-- ---------------------------------------------------------------- helpers
local function str(v)
  if type(v) == 'string' then return v end
  if type(v) == 'number' then return tostring(v) end
  return ''
end

local function sourceLabel(id)
  if id == srcIdKey then return srcLabel end
  srcIdKey = id
  local s = type(id) == 'string' and id:lower() or ''
  srcLabel = 'Windows'
  for i = 1, #SOURCE_PATTERNS do
    if s:find(SOURCE_PATTERNS[i][1], 1, true) then srcLabel = SOURCE_PATTERNS[i][2] break end
  end
  return srcLabel
end

-- Feed a raw position (seconds, -1 unknown) into an anchor. The anchor only jumps when the source
-- moved by more than RESYNC_S (a seek, a new track) or when forced; small disagreements are ignored
-- so the bar never twitches backwards when a coarse source catches up with our clock.
local function anchorFeed(a, raw, now, force)
  if force or raw ~= a.raw then
    local interp = a.pos >= 0 and (a.pos + (now - a.at)) or -1
    if force or raw < 0 or interp < 0 or math.abs(interp - raw) > RESYNC_S then a.pos = raw; a.at = now end
    a.raw = raw
  end
end

local function anchorValue(a, now, playing, dur)
  if a.pos < 0 then return -1 end
  local v = playing and (a.pos + (now - a.at)) or a.pos
  if dur > 0 and v > dur then v = dur end
  return v
end

-- Trim `s` with an ellipsis so it fits `w` pixels in the *current* font. Cached per slot on
-- (string, width); the linear scan only runs when the track or the window width changes.
-- Steps by UTF-8 character so a multi-byte title is never cut mid-sequence.
local function fitText(slot, s, w)
  w = math.floor(w)
  if slot.src == s and slot.w == w then return slot.str end
  slot.src, slot.w = s, w
  if s == '' or ui.measureText(s).x <= w then slot.str = s return s end
  local best, n, i = '', #s, 1
  while i <= n do
    local c = s:byte(i)
    local len = (c < 0x80 and 1) or (c < 0xE0 and 2) or (c < 0xF0 and 3) or 4
    local j = i + len - 1
    local cand = s:sub(1, j) .. ELLIPSIS
    if ui.measureText(cand).x > w then break end
    best = cand
    i = j + 1
  end
  if best == '' then best = ELLIPSIS end
  slot.str = best
  return best
end

local function fmtTime(sec)
  if sec < 0 then return '--:--' end
  local m = math.floor(sec / 60)
  return string.format('%d:%02d', m, math.floor(sec - m * 60))
end

-- "m:ss / m:ss", rebuilt only when a whole second ticks over.
local function refreshTimes()
  local pk = cur.pos >= 0 and math.floor(cur.pos) or -1
  local dk = cur.dur >= 0 and math.floor(cur.dur) or -1
  if pk ~= timesPosKey or dk ~= timesDurKey then
    timesPosKey, timesDurKey = pk, dk
    timesStr = fmtTime(pk) .. ' / ' .. fmtTime(dk)
    timesDirty = true
  end
end

local function refreshEyebrow()
  local key
  if cur.playing then key = cur.source
  elseif cfg.useServer and srv.err then key = 'SERVER OFFLINE'
  else key = '' end
  if key ~= eyebrowKey then
    eyebrowKey = key
    eyebrowStr = key == '' and 'NOW PLAYING' or ('NOW PLAYING · ' .. key:upper())
  end
end

local function refreshCompact()
  if cur.title ~= compactTitle or cur.artist ~= compactArtist then
    compactTitle, compactArtist = cur.title, cur.artist
    compactStr = cur.artist ~= '' and (cur.title .. DASH .. cur.artist) or cur.title
  end
end

-- Line heights per font, re-measured only when the UI scale changes.
local function refreshFontHeights()
  local u = ac.getUI()
  local scale = u and u.uiScale or 1
  if scale == fontScale then return end
  fontScale = scale
  ui.pushFont(ui.Font.Small); hSmall = ui.measureText('Ag').y; ui.popFont()
  hMain = ui.measureText('Ag').y
  ui.pushFont(ui.Font.Title); hTitle = ui.measureText('Ag').y; ui.popFont()
end

-- ---------------------------------------------------------------- source A: Windows media session
local function readWindows(now)
  local mp = ac.currentlyPlaying()
  if not mp or not mp.isPlaying then return false end
  local title = str(mp.title)
  if title == '' then return false end
  local dur = tonumber(mp.trackDuration) or -1
  local raw = tonumber(mp.trackPosition) or -1
  local changed = title ~= lastWinTitle
  lastWinTitle = title
  anchorFeed(anchorWin, raw, now, changed)
  cur.playing, cur.mode = true, 'windows'
  cur.title, cur.artist, cur.album = title, str(mp.artist), str(mp.album)
  cur.source = sourceLabel(mp.sourceID)
  cur.dur = dur
  cur.pos = anchorValue(anchorWin, now, true, dur)
  return true
end

-- ---------------------------------------------------------------- source B: widget server
local function onServerResponse(err, resp)
  inFlight = false
  local body = (not err) and resp and resp.status == 200 and resp.body or nil
  local t = body and JSON.parse(body) or nil
  if type(t) ~= 'table' then
    srv.err = true
    srv.playing = false
    return
  end
  srv.err = false
  srv.playing = t.playing == true
  srv.title, srv.artist, srv.album, srv.id = str(t.title), str(t.artist), str(t.album), str(t.id)
  local d, p = tonumber(t.duration), tonumber(t.progress)
  srv.dur = d and d >= 0 and d / 1000 or -1
  srv.progress = p and p >= 0 and p / 1000 or -1
  local now = os.preciseClock()
  local changed = srv.id ~= lastSrvId or srv.title ~= cur.title
  lastSrvId = srv.id
  -- paused: snap to the reported progress so a frozen bar shows exactly what the server says
  anchorFeed(anchorSrv, srv.progress, now, changed or not srv.playing)
end

local function pollServer(now)
  if inFlight then
    if now - lastPollAt > REQUEST_TIMEOUT_S then inFlight = false else return end
  end
  if now - lastPollAt < math.max(1, cfg.pollSeconds or 5) then return end
  if cfg.baseUrl ~= lastUrlBase then
    lastUrlBase = cfg.baseUrl
    local base = str(cfg.baseUrl)
    if base:sub(-1) == '/' then base = base:sub(1, -2) end
    pollUrl = base .. '/now-playing'
  end
  inFlight = true
  lastPollAt = now
  web.get(pollUrl, onServerResponse)
end

local function readServer(now)
  if not srv.playing or srv.title == '' then return false end
  cur.playing, cur.mode = true, 'server'
  cur.title, cur.artist, cur.album = srv.title, srv.artist, srv.album
  cur.source = 'server'
  cur.dur = srv.dur
  cur.pos = anchorValue(anchorSrv, now, true, srv.dur)
  return true
end

-- ---------------------------------------------------------------- per-frame update
local function update(now)
  local have = readWindows(now)
  if not have and cfg.useServer then
    pollServer(now)
    have = readServer(now)
  end
  if not have then
    cur.playing, cur.mode = false, 'none'
    cur.title, cur.artist, cur.album, cur.source = '', '', '', ''
    cur.pos, cur.dur = -1, -1
  end
  if cur.pos >= 0 and cur.dur > 0 then
    cur.frac = math.min(1, math.max(0, cur.pos / cur.dur))
  else
    cur.frac = 0
  end
  refreshTimes()
  refreshEyebrow()
end

-- ---------------------------------------------------------------- drawing
local drawCompact  -- forward declaration: the card degrades to the compact line in very short windows

-- Full card. Rows are admitted in order of importance until the height runs out: title first,
-- then artist, then the bar row (pinned to the bottom edge), then the eyebrow on top. A window
-- too short even for the Title font falls back to the compact single line instead.
local function drawCard(ox, oy, W, H)
  if hTitle > H then return drawCompact(ox, oy, W, H) end
  local rowH = math.max(hSmall, BAR_H)
  local used = hTitle
  local showArtist = cur.playing and used + GAP_ROW + hMain <= H
  if showArtist then used = used + GAP_ROW + hMain end
  local showBar = cur.playing and used + GAP_BAR + rowH <= H
  if showBar then used = used + GAP_BAR + rowH end
  local showEyebrow = used + GAP_EYEBROW + hSmall <= H

  local y = 0
  if showEyebrow then
    ui.pushFont(ui.Font.Small)
    p1:set(ox, oy + y)
    ui.drawText(eyebrowStr, p1, C_DIM)
    ui.popFont()
    y = y + hSmall + GAP_EYEBROW
  end

  ui.pushFont(ui.Font.Title)
  if cur.playing then
    local s = fitText(fitTitle, cur.title, W)
    p1:set(ox, oy + y)
    ui.drawText(s, p1, C_TEXT)
  else
    local s = fitText(fitNothing, 'nothing playing', W)
    p1:set(ox, oy + y)
    ui.drawText(s, p1, C_MUTED)
  end
  ui.popFont()
  y = y + hTitle

  if showArtist then
    y = y + GAP_ROW
    local s = fitText(fitArtist, cur.artist ~= '' and cur.artist or '—', W)
    p1:set(ox, oy + y)
    ui.drawText(s, p1, C_ARTIST)
    y = y + hMain
  end

  if showBar then
    local rowY = H - rowH
    local barW = W
    ui.pushFont(ui.Font.Small)
    if timesDirty then timesW = ui.measureText(timesStr).x; timesDirty = false end
    if W - timesW - TIMES_GAP >= MIN_BAR_W then
      p1:set(ox + W - timesW, oy + rowY + (rowH - hSmall) * 0.5)
      ui.drawText(timesStr, p1, C_DIM)
      barW = W - timesW - TIMES_GAP
    end
    ui.popFont()
    local by = oy + rowY + (rowH - BAR_H) * 0.5
    p1:set(ox, by)
    p2:set(ox + barW, by + BAR_H)
    ui.drawRectFilled(p1, p2, C_TRACK, 2)
    if cur.frac > 0 then
      p2:set(ox + barW * cur.frac, by + BAR_H)
      ui.drawRectFilled(p1, p2, C_FILL, 2)
    end
  end
end

-- Compact: one vertically centred line, "title — artist" or a muted "nothing playing".
drawCompact = function(ox, oy, W, H)
  local y = math.max(0, (H - hMain) * 0.5)
  if cur.playing then
    refreshCompact()
    local s = fitText(fitCompact, compactStr, W)
    p1:set(ox, oy + y)
    ui.drawText(s, p1, C_TEXT)
  else
    local s = fitText(fitNothingLine, 'nothing playing', W)
    p1:set(ox, oy + y)
    ui.drawText(s, p1, C_MUTED)
  end
end

function script.windowMain(dt)
  if not bgSet then
    ac.setWindowBackground('main', BG, true)
    bgSet = true
  end
  update(os.preciseClock())

  local origin = ui.getCursor()
  local size = ui.availableSpace()
  local W, H = size.x, size.y
  if W < 4 or H < 4 then return end
  refreshFontHeights()

  if cfg.compact then
    drawCompact(origin.x, origin.y, W, H)
  else
    drawCard(origin.x, origin.y, W, H)
  end
end

-- ---------------------------------------------------------------- settings
local statusMode, statusTitle, statusErr, statusStr = nil, nil, nil, ''
local function statusText()
  if cur.mode == statusMode and cur.title == statusTitle and srv.err == statusErr then return statusStr end
  statusMode, statusTitle, statusErr = cur.mode, cur.title, srv.err
  if cur.mode == 'windows' then statusStr = 'Source: Windows (' .. cur.source .. ') — ' .. cur.title
  elseif cur.mode == 'server' then statusStr = 'Source: widget server — ' .. cur.title
  elseif cfg.useServer and srv.err then statusStr = 'Source: none (server unreachable)'
  else statusStr = 'Source: none' end
  return statusStr
end

function script.windowSettings(dt)
  ui.text('Sources')
  if ui.checkbox('Fall back to the widget server', cfg.useServer) then cfg.useServer = not cfg.useServer end
  local url = ui.inputText('Base URL', cfg.baseUrl)
  if url ~= cfg.baseUrl then cfg.baseUrl = url end
  local secs = ui.slider('Poll every', cfg.pollSeconds, 1, 30, '%.0f s')
  secs = math.floor(secs + 0.5)
  if secs ~= cfg.pollSeconds then cfg.pollSeconds = secs end
  ui.separator()
  ui.text('Layout')
  if ui.checkbox('Compact: one line, no bar', cfg.compact) then cfg.compact = not cfg.compact end
  ui.separator()
  ui.textWrapped(statusText())
end
