-- JamPure Stream Ticker — in-game Twitch event ticker fed by the widget server (server.js, :3000).
-- Polls GET <baseUrl>/widget-events/recent?since=<lastSeq>, shows the newest event as a big headline
-- with a coloured tag, a compact history list under it with "12 s ago" style timestamps, a status dot
-- for the poll health and an optional LIVE / offline footer from GET <baseUrl>/twitch/stream-status.
-- Target: CSP 0.2.11+ / 0.3.0 previews. Single file, no requires; the only global is `script`.

script = script or {}

-- ---------------------------------------------------------------- settings (persistent, edited in windowSettings)
local cfg = ac.storage{
  baseUrl = 'http://localhost:3000',  -- widget server root, no trailing slash needed
  pollSeconds = 2,                    -- events poll interval (min 1)
  showSeconds = 8,                    -- how long the newest event stays as the big headline
  maxList = 4,                        -- compact history rows under the headline
  showStream = true,                  -- poll /twitch/stream-status every 30 s and draw the footer
}

-- ---------------------------------------------------------------- constants
local QUEUE_MAX = 50            -- events kept in memory
local FAILS_BEFORE_BACKOFF = 3  -- consecutive poll failures before slowing down
local BACKOFF_S = 10            -- poll interval while backed off
local STREAM_POLL_S = 30        -- stream-status interval
local ERR_MAX_CHARS = 26        -- status error text is cut to this many characters

local TAG_H = 16                -- tag row height (Small font)
local HEAD_H = 40               -- headline row height (Huge font)
local ROW_H = 16                -- history row pitch (Small font)
local FOOT_H = 16               -- footer height (Small font)
local DOT_R = 4                 -- status dot radius
local GAP = 4                   -- small vertical gap between blocks
local TAG_PAD = 5               -- horizontal padding inside the tag pill

-- Colours per event type. Unknown events fall back to C_UNKNOWN.
local C_FOLLOW = rgbm(0.25, 0.90, 1.00, 1)   -- cyan
local C_SUB = rgbm(1.00, 0.35, 0.95, 1)      -- fuchsia
local C_CHEER = rgbm(1.00, 0.88, 0.20, 1)    -- yellow
local C_TIP = rgbm(0.55, 1.00, 0.30, 1)      -- lime
local C_UNKNOWN = rgbm(0.62, 0.62, 0.62, 1)  -- grey
local C_TEXT = rgbm(0.95, 0.95, 0.95, 1)
local C_DIM = rgbm(0.60, 0.60, 0.60, 1)
local C_TAGTEXT = rgbm(0.05, 0.05, 0.05, 1)  -- dark text on the coloured pill
local C_OK = rgbm(0.30, 0.90, 0.40, 1)
local C_BAD = rgbm(1.00, 0.30, 0.30, 1)
local C_WAIT = rgbm(0.55, 0.55, 0.55, 1)
local C_LIVE = rgbm(1.00, 0.30, 0.35, 1)
local C_LINE = rgbm(1, 1, 1, 0.12)
local BG = rgbm(0, 0, 0, 0.55)

-- ---------------------------------------------------------------- state
local queue = {}            -- event records, oldest first, newest at #queue
local lastSeq = 0           -- highest seq seen from the server
local inFlight = false      -- events request open
local lastPollAt = -1e9     -- os.preciseClock() of the last events request
local failures = 0          -- consecutive failed polls
local pollState = 0         -- 0 = no response yet, 1 = last poll ok, 2 = last poll failed
local errText = ''          -- shortened error for the status line
local errW = -1             -- pixel width of errText under the Small font (-1 = recompute)
local headline = nil        -- event record currently shown big (nil when none)
local headlineAt = -1e9     -- os.preciseClock() when it was promoted
local streamInFlight = false
local lastStreamAt = -1e9
local streamText = 'stream: connecting…'
local streamLive = false
local streamOk = false      -- at least one good /twitch/stream-status response
local bgSet = false

-- scratch vectors reused every frame so the hot path does not allocate
local pA, pB, tp = vec2(), vec2(), vec2()

-- ---------------------------------------------------------------- small helpers
local function trimSlash(url)
  url = tostring(url or '')
  if url:sub(-1) == '/' then url = url:sub(1, -2) end
  return url
end

local function textWidth(s)
  local m = ui.measureText(s)
  return m and m.x or (#s * 7)
end

-- Width cache for the handful of fixed strings drawn every frame under the Small font (tags, status
-- messages). ui.measureText returns a fresh vec2, so measuring per frame would allocate.
local smallW = {}
local function smallWidth(s)
  local w = smallW[s]
  if w == nil then w = textWidth(s); smallW[s] = w end
  return w
end

-- Cut a string to fit maxW pixels with a trailing ellipsis, never splitting a UTF-8 sequence.
-- Only called when a cached string goes stale, never every frame.
local function trimToWidth(s, maxW)
  if textWidth(s) <= maxW then return s end
  local cut = #s
  while cut > 0 do
    cut = cut - 1
    while cut > 0 do
      local b = s:byte(cut + 1)
      if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
    end
    if cut == 0 then return '…' end
    local t = s:sub(1, cut) .. '…'
    if textWidth(t) <= maxW then return t end
  end
  return '…'
end

local function shortErr(s)
  s = tostring(s or 'error')
  if #s > ERR_MAX_CHARS then s = s:sub(1, ERR_MAX_CHARS) .. '…' end
  return s
end

local function numOr(v, d)
  local n = tonumber(v)
  if n == nil then return d end
  return n
end

-- Currency → symbol for tips; anything else is printed as "12.00 XYZ".
local CURRENCY = { USD = '$', EUR = '€', GBP = '£', CAD = 'CA$', AUD = 'A$', JPY = '¥' }
local function money(amount, currency)
  local a = numOr(amount, 0)
  local c = tostring(currency or 'USD'):upper()
  local sym = CURRENCY[c]
  if sym then return string.format('%s%.2f', sym, a) end
  return string.format('%.2f %s', a, c)
end

-- Twitch tier can arrive as "1000"/"2000"/"3000", "Prime", or plain 1/2/3.
local function tierText(tier)
  if tier == nil then return 'Tier 1' end
  local n = tonumber(tier)
  if n then
    if n >= 1000 then n = n / 1000 end
    return string.format('Tier %.0f', n)
  end
  return tostring(tier)
end

-- ---------------------------------------------------------------- event records
-- Everything the renderer needs is computed once here, at push time, so drawing only reads strings.
local function makeRecord(ev)
  local data = type(ev.data) == 'table' and ev.data or {}
  local kind = tostring(ev.event or 'event')
  local name = tostring(data.name or data.user or data.username or '')
  local rec = { seq = numOr(ev.seq, 0), t = numOr(ev.t, os.time() * 1000), kind = kind,
    tag = '', text = '', color = C_UNKNOWN, relKey = -1, relStr = '', relW = 0, fitW = -1, fitStr = '', bigW = -1, bigStr = '' }
  if kind == 'follow' then
    rec.tag, rec.color, rec.text = 'NEW FOLLOW', C_FOLLOW, name
  elseif kind == 'sub' then
    rec.tag, rec.color = 'SUB', C_SUB
    if data.gift == true or (tonumber(data.gift) or 0) > 0 then
      rec.text = string.format('%s · gift x%.0f', name, numOr(data.total, numOr(data.gift, 1)))
    else
      rec.text = name .. ' · ' .. tierText(data.tier)
    end
  elseif kind == 'cheer' then
    rec.tag, rec.color = 'CHEER', C_CHEER
    rec.text = string.format('%s · %.0f bits', name, numOr(data.bits, 0))
  elseif kind == 'tip' then
    rec.tag, rec.color = 'TIP', C_TIP
    rec.text = name .. ' · ' .. money(data.amount, data.currency)
  else
    rec.tag, rec.color, rec.text = kind:upper(), C_UNKNOWN, name
  end
  if rec.text == '' then rec.text = kind end
  return rec
end

local function pushEvent(ev)
  local rec = makeRecord(ev)
  queue[#queue + 1] = rec
  if #queue > QUEUE_MAX then table.remove(queue, 1) end
  headline = rec
  headlineAt = os.preciseClock()
end

-- Relative time text, re-formatted only when the displayed number changes.
local function relText(rec, nowMs)
  local s = math.floor((nowMs - rec.t) / 1000)
  if s < 0 then s = 0 end
  -- one integer key per displayed value; the offsets keep the s / min / h / d ranges from colliding
  local key
  if s < 60 then key = s
  elseif s < 3600 then key = 100000 + math.floor(s / 60)
  elseif s < 86400 then key = 200000 + math.floor(s / 3600)
  else key = 300000 + math.floor(s / 86400) end
  if rec.relKey ~= key then
    rec.relKey = key
    if key < 100000 then rec.relStr = string.format('%.0f s ago', key)
    elseif key < 200000 then rec.relStr = string.format('%.0f min ago', key - 100000)
    elseif key < 300000 then rec.relStr = string.format('%.0f h ago', key - 200000)
    else rec.relStr = string.format('%.0f d ago', key - 300000) end
    rec.relW = textWidth(rec.relStr)   -- caller has the Small font pushed
  end
  return rec.relStr
end

-- Trimmed copies of the text for the list row (Small font) and the headline (Huge font), cached per width.
local function rowText(rec, w)
  if rec.fitW ~= w then rec.fitW = w; rec.fitStr = trimToWidth(rec.text, w) end
  return rec.fitStr
end
local function bigText(rec, w)
  if rec.bigW ~= w then rec.bigW = w; rec.bigStr = trimToWidth(rec.text, w) end
  return rec.bigStr
end

-- ---------------------------------------------------------------- events polling
local function onEvents(err, response)
  inFlight = false
  if err ~= nil or response == nil then
    failures = failures + 1; pollState = 2; errText = shortErr(err or 'no response'); errW = -1
    return
  end
  if (response.status or 0) >= 400 then
    failures = failures + 1; pollState = 2; errText = shortErr('HTTP ' .. tostring(response.status)); errW = -1
    return
  end
  local data = JSON.parse(response.body or '')
  if type(data) ~= 'table' then
    failures = failures + 1; pollState = 2; errText = shortErr('bad JSON'); errW = -1
    return
  end
  failures = 0; pollState = 1; errText = ''
  local events = type(data.events) == 'table' and data.events or nil
  local serverSeq = numOr(data.seq, lastSeq)
  if events then
    -- events may arrive out of order; only seq > lastSeq are new, and lastSeq follows the highest one
    for i = 1, #events do
      local ev = events[i]
      if type(ev) == 'table' then
        local seq = numOr(ev.seq, 0)
        if seq > lastSeq then
          pushEvent(ev)
          lastSeq = seq
        end
      end
    end
  end
  -- first call (since=0) returns only the current seq: store it so the next poll asks for what follows
  if serverSeq > lastSeq then lastSeq = serverSeq end
end

local function pollEvents(now)
  if inFlight then return end
  local interval = math.max(1, numOr(cfg.pollSeconds, 2))
  if failures >= FAILS_BEFORE_BACKOFF then interval = BACKOFF_S end
  if now - lastPollAt < interval then return end
  lastPollAt = now
  inFlight = true
  web.get(trimSlash(cfg.baseUrl) .. '/widget-events/recent?since=' .. string.format('%.0f', lastSeq), onEvents)
end

-- ---------------------------------------------------------------- stream status polling
local function onStream(err, response)
  streamInFlight = false
  if err ~= nil or response == nil or (response.status or 0) >= 400 then
    if not streamOk then streamText = 'stream: unavailable'; streamLive = false end
    return
  end
  local data = JSON.parse(response.body or '')
  if type(data) ~= 'table' then
    if not streamOk then streamText = 'stream: unavailable'; streamLive = false end
    return
  end
  streamOk = true
  if data.live == true then
    streamLive = true
    streamText = string.format('LIVE · %.0f viewers · %.0f followers', numOr(data.viewers, 0), numOr(data.followers, 0))
  else
    streamLive = false
    streamText = 'offline'
  end
end

local function pollStream(now)
  if streamInFlight or not cfg.showStream then return end
  if inFlight then return end   -- wait for the events poll so only one request is ever open
  if now - lastStreamAt < STREAM_POLL_S then return end
  lastStreamAt = now
  streamInFlight = true
  web.get(trimSlash(cfg.baseUrl) .. '/twitch/stream-status', onStream)
end

-- ---------------------------------------------------------------- main window
function script.windowMain(dt)
  if not bgSet then
    ac.setWindowBackground('main', BG, true)
    bgSet = true
  end
  local now = os.preciseClock()
  pollEvents(now)
  pollStream(now)

  local origin = ui.getCursor()
  local size = ui.availableSpace()
  local x0, w = origin.x, size.x
  local y, bottom = origin.y, origin.y + size.y
  local right = x0 + w
  local nowMs = os.time() * 1000

  -- headline stays for showSeconds after it was promoted
  local showFor = math.max(0, numOr(cfg.showSeconds, 8))
  local headActive = headline ~= nil and (now - headlineAt) < showFor

  -- ---- tag row + status dot (top-right)
  ui.pushFont(ui.Font.Small)
  local dotX = right - DOT_R - 2
  local dotC = C_WAIT
  if pollState == 1 then dotC = C_OK elseif pollState == 2 then dotC = C_BAD end
  tp:set(dotX, y + TAG_H * 0.5)
  ui.drawCircleFilled(tp, DOT_R, dotC, 12)
  local statusW = 0
  if pollState == 2 and errText ~= '' then
    -- shortened error to the left of the dot, in red (width measured once per new error text)
    if errW < 0 then errW = textWidth(errText) end
    local ew = errW
    if ew < w - 40 then
      tp:set(dotX - DOT_R - 4 - ew, y + 1)
      ui.drawText(errText, tp, C_BAD)
      statusW = ew + DOT_R + 4
    end
  end
  local tagRight = dotX - DOT_R - 6 - statusW
  if headActive then
    local tw = smallWidth(headline.tag)
    if x0 + tw + TAG_PAD * 2 <= tagRight then
      pA:set(x0, y + 1)
      pB:set(x0 + tw + TAG_PAD * 2, y + TAG_H - 1)
      ui.drawRectFilled(pA, pB, headline.color, 3)
      tp:set(x0 + TAG_PAD, y + 1)
      ui.drawText(headline.tag, tp, C_TAGTEXT)
    end
  else
    -- quiet state: say what we are doing instead of leaving the row blank
    local msg = (pollState == 0) and 'connecting…' or (#queue == 0 and 'listening for events' or 'recent events')
    if smallWidth(msg) <= tagRight - x0 then
      tp:set(x0, y + 1)
      ui.drawText(msg, tp, C_DIM)
    end
  end
  ui.popFont()
  y = y + TAG_H

  -- ---- headline (Huge font) in the event colour
  if headActive and y + HEAD_H <= bottom then
    ui.pushFont(ui.Font.Huge)
    tp:set(x0, y)
    ui.drawText(bigText(headline, w), tp, headline.color)
    ui.popFont()
    y = y + HEAD_H
  elseif not headActive and #queue == 0 and y + HEAD_H <= bottom then
    ui.pushFont(ui.Font.Title)
    tp:set(x0, y + 8)
    ui.drawText('no events yet', tp, C_DIM)
    ui.popFont()
    y = y + HEAD_H
  end

  -- ---- footer reservation so the list never paints over it
  local footerH = 0
  if cfg.showStream and (bottom - y) >= FOOT_H + ROW_H then footerH = FOOT_H end

  -- ---- compact history list: newest first, skipping the headline event while it is shown big
  local maxList = math.max(0, math.floor(numOr(cfg.maxList, 4) + 0.5))
  local first = headActive and (#queue - 1) or #queue
  local rowsFit = math.floor((bottom - footerH - y - GAP) / ROW_H)
  local rows = math.min(maxList, first, math.max(0, rowsFit))
  if rows > 0 then
    y = y + GAP
    pA:set(x0, y - 2); pB:set(right, y - 2)
    ui.drawLine(pA, pB, C_LINE, 1)
    ui.pushFont(ui.Font.Small)
    for k = 0, rows - 1 do
      local rec = queue[first - k]
      if rec == nil then break end
      local rel = relText(rec, nowMs)
      local relW = rec.relW
      -- layout: [tag] [text .................] [12 s ago]
      local tagW = smallWidth(rec.tag)
      local x = x0
      tp:set(x, y)
      ui.drawText(rec.tag, tp, rec.color)
      x = x + tagW + 6
      local textW = right - relW - 6 - x
      if textW > 20 then
        tp:set(x, y)
        ui.drawText(rowText(rec, textW), tp, C_TEXT)
      end
      if x0 + relW <= right then
        tp:set(right - relW, y)
        ui.drawText(rel, tp, C_DIM)
      end
      y = y + ROW_H
    end
    ui.popFont()
  end

  -- ---- footer: stream status
  if footerH > 0 then
    local fy = bottom - FOOT_H
    ui.pushFont(ui.Font.Small)
    pA:set(x0, fy - 1); pB:set(right, fy - 1)
    ui.drawLine(pA, pB, C_LINE, 1)
    tp:set(x0, fy + 1)
    ui.drawText(streamText, tp, streamLive and C_LIVE or C_DIM)
    ui.popFont()
    y = bottom
  end

  -- hand the height we painted back to the layout so the window's content size stays sane
  ui.offsetCursorY(y - origin.y)
end

-- ---------------------------------------------------------------- settings window
local statsN, statsSeq, statsStr = -1, -1, ''
local function statsText()
  if statsN ~= #queue or statsSeq ~= lastSeq then
    statsN, statsSeq = #queue, lastSeq
    statsStr = string.format('%.0f events buffered · last seq %.0f', statsN, statsSeq)
  end
  return statsStr
end

function script.windowSettings(dt)
  ui.pushFont(ui.Font.Small)
  ui.text('Widget server')
  ui.popFont()
  local url = ui.inputText('Base URL', cfg.baseUrl)
  if type(url) == 'string' and url ~= cfg.baseUrl then cfg.baseUrl = url end

  ui.separator()
  -- sliders return floats; round so the intervals stay whole seconds
  cfg.pollSeconds = math.max(1, math.floor(ui.slider('##poll', cfg.pollSeconds, 1, 30, 'Poll every %.0f s') + 0.5))
  cfg.showSeconds = math.max(1, math.floor(ui.slider('##show', cfg.showSeconds, 1, 60, 'Headline for %.0f s') + 0.5))
  cfg.maxList = math.max(0, math.floor(ui.slider('##list', cfg.maxList, 0, 12, 'History rows: %.0f') + 0.5))
  if ui.checkbox('Show stream status footer', cfg.showStream) then cfg.showStream = not cfg.showStream end

  ui.separator()
  -- local-only fake follow so the layout can be checked without the server sending anything
  if ui.button('Push test event') then
    pushEvent({ seq = lastSeq, t = os.time() * 1000, event = 'follow', data = { name = 'test_viewer' } })
  end
  ui.pushFont(ui.Font.Small)
  ui.text(statsText())
  ui.popFont()
end
