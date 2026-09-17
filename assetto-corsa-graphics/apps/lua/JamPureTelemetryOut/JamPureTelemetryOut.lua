-- JamPure Telemetry Out — pushes a JSON snapshot of the player car to the widget server (server.js, :3000)
-- every cfg.intervalMs so the OBS overlays can show live speed / gear / rpm / fuel / lap data.
-- POST <baseUrl>/ac/telemetry, header Content-Type: application/json, body = JSON payload; server answers {"ok":true}.
-- The sender runs off a 50 ms timer (setInterval), not off the window, so telemetry keeps flowing while the
-- panel is closed (LAZY = PARTIAL keeps the script alive after the first open). The window only reports:
-- a big status word, the send rate actually achieved, a one-line summary of the last payload and counters.
-- Target: CSP 0.2.11+ / 0.3.0 previews. Single file, no requires; the only global is `script`.

script = script or {}

-- ---------------------------------------------------------------- settings (persistent, edited in windowSettings)
local cfg = ac.storage{
  enabled = true,                     -- master switch for the automatic sender
  baseUrl = 'http://localhost:3000',  -- widget server root; a trailing slash is tolerated
  intervalMs = 250,                   -- send period, clamped to INTERVAL_MIN..INTERVAL_MAX every tick
  sendWhenPaused = false,             -- keep posting while sim.dt == 0 (pause menu, replay paused)
}

-- ---------------------------------------------------------------- constants
local INTERVAL_MIN, INTERVAL_MAX = 100, 2000
local TIMER_MS = 50            -- the sender timer wakes this often and checks whether a send is due
local RATE_WINDOW_MIN_S = 1.0  -- achieved rate is averaged over max(this, 2 x interval)
local ERR_MAX_CHARS = 60       -- error strings are cut to this many characters before display
local ENDPOINT = '/ac/telemetry'
local HEADERS = { ['Content-Type'] = 'application/json' }  -- one table, reused for every request

-- Colours: high contrast on the dark translucent panel.
local C_OK = rgbm(0.30, 0.90, 0.40, 1)      -- green: SENDING
local C_OFF = rgbm(0.62, 0.62, 0.62, 1)     -- grey: PAUSED / OFF
local C_BAD = rgbm(1.00, 0.30, 0.30, 1)     -- red: ERROR
local C_DIM = rgbm(0.62, 0.62, 0.62, 1)
local C_ACCENT = rgbm(0.25, 0.90, 1.00, 1)  -- cyan: last payload summary
local C_BUSY = rgbm(1.00, 0.88, 0.20, 1)    -- yellow dot while a request is in flight
local C_LINE = rgbm(1, 1, 1, 0.12)
local BG = rgbm(0, 0, 0, 0.55)

-- ---------------------------------------------------------------- state
local inFlight = false      -- exactly one request may be open; ticks are skipped while it is
local sentAt = 0            -- os.preciseClock() when the open request left (round-trip timing)
local lastSendAt = -1e9     -- clock of the last issued (or skipped) tick, drives the interval gate
local sends = 0             -- requests issued
local failures = 0          -- requests that errored or returned a non-2xx status
local skipped = 0           -- ticks skipped because the previous request was still pending
local lastError = ''        -- last error string, kept even after the link recovers
local errorActive = false   -- the most recent completed request failed
local lastRttMs = 0         -- round trip of the most recent completed request
local rateHz = 0            -- sends per second actually achieved
local rateCount = 0         -- sends inside the current measuring window
local rateStart = -1        -- window start clock (-1 = not started yet)
local bgSet = false
local payload = {}          -- one table reused for every snapshot (JSON.stringify reads it fresh each time)

-- Strings shown by the panel. They are rebuilt only when their inputs change (send / response / once a
-- second for the rate), so the per-frame draw path formats nothing.
local summaryText = 'waiting for first snapshot'
local countersText = 'sent 0  fail 0  skip 0'
local rateText = '0.0 /s  (target 4.0)'
local errText = ''

-- scratch vectors reused every frame so drawing does not allocate
local pA, pB = vec2(), vec2()

-- ---------------------------------------------------------------- small helpers
local function trimSlash(url)
  url = tostring(url or '')
  if url:sub(-1) == '/' then url = url:sub(1, -2) end
  return url
end

-- Reads cfg.intervalMs, rounds and clamps it (old stored values or a dragged slider can be out of range)
-- and writes the fixed value back so the settings panel shows what is really used. Returns milliseconds.
local function clampInterval()
  local v = tonumber(cfg.intervalMs) or 250
  v = math.floor(v + 0.5)
  if v < INTERVAL_MIN then v = INTERVAL_MIN elseif v > INTERVAL_MAX then v = INTERVAL_MAX end
  if v ~= cfg.intervalMs then cfg.intervalMs = v end
  return v
end

local function cut(s, n)
  s = tostring(s or '')
  if n < 4 then n = 4 end
  if #s > n then return s:sub(1, n - 3) .. '...' end
  return s
end

local function gearLabel(g)
  g = tonumber(g) or 0
  if g < 0 then return 'R' elseif g == 0 then return 'N' end
  return string.format('%d', g)
end

local function round(v) return math.floor((tonumber(v) or 0) + 0.5) end

-- Per-row cache so text is only re-cut when the source string or the available width changes.
local function fitted(cache, s, maxChars)
  if cache.src ~= s or cache.n ~= maxChars then
    cache.src, cache.n = s, maxChars
    cache.out = cut(s, maxChars)
  end
  return cache.out
end
local fitStatus, fitErr, fitRate, fitSummary, fitCounters = {}, {}, {}, {}, {}

-- Settings-panel lines, rebuilt only when their source changes.
local urlLine = { src = nil, out = '' }
local errLine = { src = nil, out = '' }
local function lineFor(cache, key, build)
  if cache.src ~= key then cache.src, cache.out = key, build(key) end
  return cache.out
end
local function buildUrlLine(u) return 'POST ' .. trimSlash(u) .. ENDPOINT end
local function buildErrLine(e) return 'Last error: ' .. tostring(e or '') end

local function rebuildCounters()
  countersText = string.format('sent %d  fail %d  skip %d  rtt %d ms', sends, failures, skipped, round(lastRttMs))
end

-- ---------------------------------------------------------------- payload
-- Fills the reused payload table from the player car and the sim. Every field is nil-guarded because
-- names can be nil (car not spawned yet, weird online slots) and the server expects all keys present.
local function buildPayload(car, sim)
  payload.car = ac.getCarName(0) or ''
  payload.carId = ac.getCarID(0) or ''
  payload.driver = ac.getDriverName(0) or ''
  payload.track = ac.getTrackName() or ''
  payload.trackId = ac.getTrackID() or ''
  payload.speedKmh = car.speedKmh or 0
  payload.gear = car.gear or 0
  payload.rpm = car.rpm or 0
  payload.rpmLimiter = car.rpmLimiter or 0
  payload.fuel = car.fuel or 0
  payload.maxFuel = car.maxFuel or 0
  payload.throttle = car.gas or 0
  payload.brake = car.brake or 0
  payload.lapTimeMs = car.lapTimeMs or 0
  payload.bestLapMs = car.bestLapTimeMs or 0
  payload.lastLapMs = car.previousLapTimeMs or 0
  payload.lap = car.lapCount or 0
  payload.position = car.racePosition or 0
  payload.carsCount = sim.carsCount or 0
  payload.online = sim.isOnlineRace == true
  payload.headlights = car.headlightsActive == true
  payload.timeHours = sim.timeHours or 0
  payload.t = os.time()
  -- one-line summary for the panel, refreshed here rather than every frame
  summaryText = string.format('%d km/h   G%s   %d rpm   %.1f L',
    round(payload.speedKmh), gearLabel(payload.gear), round(payload.rpm), tonumber(payload.fuel) or 0)
end

-- ---------------------------------------------------------------- web
local function onResponse(err, response)
  inFlight = false
  lastRttMs = (os.preciseClock() - sentAt) * 1000
  local failed, why = false, nil
  if err then
    failed, why = true, tostring(err)
  elseif type(response) ~= 'table' or type(response.status) ~= 'number' then
    failed, why = true, 'no response'
  elseif response.status < 200 or response.status >= 300 then
    failed, why = true, 'HTTP ' .. tostring(response.status)
  end
  if failed then
    failures = failures + 1
    if why ~= lastError then ac.log('JamPure Telemetry Out: send failed: ' .. why) end  -- log on change only
    lastError = why
    errText = cut(why, ERR_MAX_CHARS)
  elseif errorActive then
    ac.log('JamPure Telemetry Out: link recovered')
  end
  errorActive = failed
  rebuildCounters()
end

-- Issues one POST. Returns true when a request left. The timer calls this after the enabled / paused /
-- interval gates; the settings button calls it directly (no gates), but nothing bypasses the single-in-flight rule.
local function send(now)
  if inFlight then return false end
  local car = ac.getCar(0)
  local sim = ac.getSim()
  if not car or not sim then return false end
  buildPayload(car, sim)
  local body = JSON.stringify(payload)
  inFlight = true
  sentAt = now
  lastSendAt = now
  sends = sends + 1
  rateCount = rateCount + 1
  web.post(trimSlash(cfg.baseUrl) .. ENDPOINT, HEADERS, body, onResponse)
  return true
end

-- Timer body (every TIMER_MS). Keeps the achieved-rate window, then decides whether a send is due.
local function tick()
  local now = os.preciseClock()
  local intervalMs = clampInterval()
  local interval = intervalMs / 1000

  -- Achieved rate: sends counted over a window of at least 1 s and at least two intervals, so slow
  -- settings (2000 ms) do not flicker between 0 and 1 per second.
  if rateStart < 0 then rateStart = now end
  local window = math.max(RATE_WINDOW_MIN_S, interval * 2)
  local elapsed = now - rateStart
  if elapsed >= window then
    rateHz = rateCount / elapsed
    rateCount, rateStart = 0, now
    rateText = string.format('%.1f /s  (target %.1f)', rateHz, 1000 / intervalMs)
  end

  if not cfg.enabled then return end
  local sim = ac.getSim()
  if not sim then return end
  if (sim.dt or 0) <= 0 and not cfg.sendWhenPaused then return end
  if now - lastSendAt < interval then return end
  if inFlight then
    -- previous request still pending: skip this tick entirely and wait a full interval before retrying
    skipped = skipped + 1
    lastSendAt = now
    rebuildCounters()
    return
  end
  send(now)
end

setInterval(tick, TIMER_MS)

-- ---------------------------------------------------------------- status
-- Returns a constant label and colour; nothing is allocated. Disabled beats paused beats error.
local function statusFor(sim)
  if not cfg.enabled then return 'OFF', C_OFF end
  if sim and (sim.dt or 0) <= 0 and not cfg.sendWhenPaused then return 'PAUSED', C_OFF end
  if errorActive then return 'ERROR', C_BAD end
  return 'SENDING', C_OK
end

-- ---------------------------------------------------------------- main window
function script.windowMain(dt)
  if not bgSet then ac.setWindowBackground('main', BG, true); bgSet = true end
  local origin = ui.getCursor()
  local size = ui.availableSpace()
  local w, h = size.x, size.y
  if w < 10 or h < 10 then return end
  local x0, yMax = origin.x, origin.y + h
  local y = origin.y

  -- Font sizes scale with the window so a 90x60 panel still shows the status word and the rate.
  local bigH = math.max(14, math.min(40, h * 0.32, w * 0.16))
  local bigFs = bigH * 0.85
  local smallFs = math.max(9, math.min(13, bigH * 0.5))
  local midFs = math.max(10, math.min(20, bigH * 0.75))
  local smallH, midH = smallFs + 2, midFs + 4
  local dotR = math.max(3, math.min(6, bigH * 0.15))

  local sim = ac.getSim()
  local label, color = statusFor(sim)

  -- Row 1: big status word plus an activity dot at the right edge (yellow while a request is open).
  local dotW = dotR * 2 + 6
  pA:set(x0, y)
  ui.dwriteDrawText(fitted(fitStatus, label, math.floor((w - dotW) / (bigFs * 0.6))), bigFs, pA, color)
  pB:set(x0 + w - dotR, y + bigH * 0.5)
  ui.drawCircleFilled(pB, dotR, inFlight and C_BUSY or color, 16)
  y = y + bigH + 2

  local maxSmall = math.floor(w / (smallFs * 0.55))

  -- Row 2 (only in ERROR): the error text in red, cut to the width.
  if errorActive and errText ~= '' and y + smallH <= yMax then
    pA:set(x0, y)
    ui.dwriteDrawText(fitted(fitErr, errText, maxSmall), smallFs, pA, C_BAD)
    y = y + smallH
  end

  -- Row 3: achieved send rate against the target derived from cfg.intervalMs.
  if y + smallH <= yMax then
    pA:set(x0, y)
    ui.dwriteDrawText(fitted(fitRate, rateText, maxSmall), smallFs, pA, C_DIM)
    y = y + smallH
  end

  -- thin divider
  if y + 4 + midH <= yMax then
    pA:set(x0, y + 2); pB:set(x0 + w, y + 2)
    ui.drawLine(pA, pB, C_LINE, 1)
    y = y + 4
  end

  -- Row 4: last payload summary (speed, gear, rpm, fuel) in the accent colour.
  if y + midH <= yMax then
    pA:set(x0, y)
    ui.dwriteDrawText(fitted(fitSummary, summaryText, math.floor(w / (midFs * 0.55))), midFs, pA, C_ACCENT)
    y = y + midH
  end

  -- Row 5: counters and the last round trip.
  if y + smallH <= yMax then
    pA:set(x0, y)
    ui.dwriteDrawText(fitted(fitCounters, countersText, maxSmall), smallFs, pA, C_DIM)
    y = y + smallH
  end
end

-- ---------------------------------------------------------------- settings window
function script.windowSettings(dt)
  if ui.checkbox('Enabled (auto send)', cfg.enabled == true) then cfg.enabled = not cfg.enabled end

  local url = ui.inputText('Base URL', tostring(cfg.baseUrl or ''))
  if type(url) == 'string' and url ~= cfg.baseUrl then cfg.baseUrl = url end

  local v = ui.slider('Interval', tonumber(cfg.intervalMs) or 250, INTERVAL_MIN, INTERVAL_MAX, '%.0f ms')
  if type(v) == 'number' and v ~= cfg.intervalMs then cfg.intervalMs = v end  -- write on change only; clampInterval() rounds / clamps on the next tick

  if ui.checkbox('Send while paused', cfg.sendWhenPaused == true) then cfg.sendWhenPaused = not cfg.sendWhenPaused end

  ui.separator()
  -- Manual send: ignores the enabled / paused gates, still refuses while a request is open.
  if ui.button(inFlight and 'Send now (busy)' or 'Send now') then
    send(os.preciseClock())
  end
  ui.sameLine()
  ui.pushFont(ui.Font.Small)
  ui.text(countersText)
  ui.popFont()

  ui.pushFont(ui.Font.Small)
  ui.textWrapped(lineFor(urlLine, cfg.baseUrl, buildUrlLine))
  if lastError ~= '' then ui.textWrapped(lineFor(errLine, lastError, buildErrLine)) end
  ui.popFont()
end
