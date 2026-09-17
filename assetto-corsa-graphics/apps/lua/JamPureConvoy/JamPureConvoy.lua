-- JamPure Convoy — a convoy panel for driving with friends.
-- Lists every other car in the session sorted by distance to you, with a direction arrow,
-- name, distance, speed and a colour-coded status ("with you" / "close" / "far" / "dropped").
-- Target: CSP 0.2.11+ / 0.3.0 previews. Single file, no requires; the only global is `script`.

script = script or {}

-- ---------------------------------------------------------------- settings (persistent, edited in windowSettings)
local cfg = ac.storage{
  includeAI = true,   -- offline: list AI cars too (online every connected car is always listed)
  nearM = 150,        -- "with you" threshold, metres
  dropM = 1000,       -- "dropped" threshold, metres
  maxRows = 8,        -- rows shown before "+K more"
  showSpeed = true,   -- show a km/h column
}

-- ---------------------------------------------------------------- constants
local NAME_REFRESH_S = 2      -- names are re-read this often; distances and sort refresh every frame
local CLOSE_M = 500           -- fixed "close" threshold from the spec
local ROW_H = 18              -- row pitch for ui.Font.Main
local LINE_H = 16             -- header / footer line pitch for ui.Font.Small
local BAR_W = 3               -- status bar width on the left of each row
local ARROW_X = 8             -- arrow column offset from the window's left edge
local NAME_X = 24             -- name column offset
local DIST_W = 52             -- fixed column widths, anchored to the right edge
local SPEED_W = 62
local STATUS_W = 62
local COL_GAP = 6

-- Status ids. Precedence in collect(): "with you" wins under nearM, then "dropped" over dropM,
-- then "close" under 500 m; "far" fills the gap between 500 m and dropM.
local S_WITH, S_CLOSE, S_FAR, S_DROP = 1, 2, 3, 4
local STATUS_TEXT = { 'with you', 'close', 'far', 'dropped' }
local STATUS_COLOR = {
  rgbm(0.35, 0.90, 0.40, 1),   -- green
  rgbm(1.00, 1.00, 1.00, 1),   -- white
  rgbm(0.62, 0.62, 0.62, 1),   -- gray
  rgbm(1.00, 0.58, 0.15, 1),   -- orange
}
local C_TEXT = rgbm(0.92, 0.92, 0.92, 1)
local C_DIM = rgbm(0.66, 0.66, 0.66, 1)
local C_HEADER = rgbm(0.75, 0.80, 0.86, 1)
local BG = rgbm(0, 0, 0, 0.55)

-- Direction glyphs relative to the player's heading (rel:dot(look) vs rel:dot(side)).
local ARROW_AHEAD, ARROW_BEHIND, ARROW_LEFT, ARROW_RIGHT = '▲', '▼', '◀', '▶'

-- ---------------------------------------------------------------- per-car state (allocated once, reused every frame)
local pool = {}        -- carIndex → row record
local active = {}      -- row records included this frame, sorted by distance
local names = {}       -- carIndex → raw name (refreshed every NAME_REFRESH_S)
local fitRaw, fitW, fitStr = {}, {}, {}   -- name trimmed to the column: source string, width it was built for, result
local distKey, distStr = {}, {}           -- formatted distance cache (re-formatted only when the rounded value changes)
local speedKey, speedStr = {}, {}         -- formatted speed cache
local n, nearCount = 0, 0                 -- cars listed this frame / cars under nearM
local lastNameRefresh = -1e9
local bgSet = false

-- scratch vectors reused every frame so the hot loop does not allocate
local rel = vec3()
local pA, pB, tp = vec2(), vec2(), vec2()

local function rowFor(i)
  local r = pool[i]
  if not r then
    r = { idx = i, dist = 0, speed = 0, arrow = ARROW_AHEAD, status = S_FAR }
    pool[i] = r
  end
  return r
end

local function byDist(a, b) return a.dist < b.dist end

-- ---------------------------------------------------------------- names
-- Online: driver name. Offline: car name, then car ID. Any of these can be nil (empty slot, not yet
-- synced), so always fall back to "car <i>".
local function readName(i, online)
  local s
  if online then
    s = ac.getDriverName(i)
  else
    s = ac.getCarName(i) or ac.getCarID(i)
  end
  if s == nil or s == '' then s = 'car ' .. i end
  return s
end

local function refreshNames(count, online)
  for i = 1, count - 1 do names[i] = readName(i, online) end
end

local function textWidth(s)
  local m = ui.measureText(s)
  return m and m.x or (#s * 7)
end

-- Cut a string to fit maxW pixels with a trailing ellipsis, never splitting a UTF-8 sequence.
local function trimToWidth(s, maxW)
  if textWidth(s) <= maxW then return s end
  local cut = #s
  while cut > 0 do
    cut = cut - 1
    -- step back over UTF-8 continuation bytes (10xxxxxx) so the cut lands on a character boundary
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

-- Trimmed name, cached: only re-trims when the raw name or the column width changes.
local function displayName(i, nameW)
  local raw = names[i]
  if raw == nil then return '' end
  if fitRaw[i] ~= raw or fitW[i] ~= nameW then
    fitRaw[i], fitW[i] = raw, nameW
    fitStr[i] = trimToWidth(raw, nameW)
  end
  return fitStr[i]
end

-- ---------------------------------------------------------------- number formatting (cached per car)
local function distText(r)
  local d, i = r.dist, r.idx
  -- key: whole metres under 1 km, tenths of a km above (offset so the two ranges never collide)
  local key
  if d < 1000 then key = math.floor(d + 0.5) else key = 100000 + math.floor(d / 100 + 0.5) end
  if distKey[i] ~= key then
    distKey[i] = key
    if d < 1000 then
      distStr[i] = string.format('%.0f m', key)
    else
      distStr[i] = string.format('%.1f km', (key - 100000) / 10)
    end
  end
  return distStr[i]
end

local function speedText(r)
  local i = r.idx
  local key = math.floor(r.speed + 0.5)
  if speedKey[i] ~= key then
    speedKey[i] = key
    speedStr[i] = string.format('%.0f km/h', key)
  end
  return speedStr[i]
end

local headN, headNear, headM, headStr = -1, -1, -1, ''
local function headerText(nearM)
  if headN ~= n or headNear ~= nearCount or headM ~= nearM then
    headN, headNear, headM = n, nearCount, nearM
    headStr = string.format('%.0f in session · %.0f within %.0f m', n, nearCount, nearM)
  end
  return headStr
end

local moreN, moreStr = -1, ''
local function moreText(k)
  if moreN ~= k then
    moreN = k
    moreStr = string.format('+%.0f more', k)
  end
  return moreStr
end

-- ---------------------------------------------------------------- collect: distances, direction, status, sort
local function collect(sim, me)
  local online = sim.isOnlineRace == true
  local count = sim.carsCount or 0
  local now = os.preciseClock()
  if now - lastNameRefresh >= NAME_REFRESH_S then
    refreshNames(count, online)
    lastNameRefresh = now
  end

  n, nearCount = 0, 0
  local mp, look, side = me.position, me.look, me.side
  if not (mp and look and side) then
    for k = #active, 1, -1 do active[k] = nil end
    return
  end
  local nearM, dropM, includeAI = cfg.nearM, cfg.dropM, cfg.includeAI

  for i = 1, count - 1 do
    local car = ac.getCar(i)
    if car and car.isActive and car.isConnected and car.position
      and (online or includeAI or not car.isAIControlled) then
      local op = car.position
      rel:set(op.x - mp.x, op.y - mp.y, op.z - mp.z)
      local d = rel:length()
      local fwd, lat = rel:dot(look), rel:dot(side)
      local r = rowFor(i)
      r.dist = d
      r.speed = car.speedKmh or 0
      -- whichever axis dominates decides the arrow; positive side dot is taken as "to the right"
      if math.abs(fwd) >= math.abs(lat) then
        r.arrow = (fwd >= 0) and ARROW_AHEAD or ARROW_BEHIND
      else
        r.arrow = (lat >= 0) and ARROW_RIGHT or ARROW_LEFT
      end
      if d < nearM then
        r.status = S_WITH
        nearCount = nearCount + 1
      elseif d > dropM then
        r.status = S_DROP
      elseif d < CLOSE_M then
        r.status = S_CLOSE
      else
        r.status = S_FAR
      end
      -- a car that joined since the last 2 s refresh gets its name straight away
      if names[i] == nil then names[i] = readName(i, online) end
      n = n + 1
      active[n] = r
    end
  end
  -- drop stale tail entries so #active == n, then sort nearest first
  for k = #active, n + 1, -1 do active[k] = nil end
  table.sort(active, byDist)
end

-- ---------------------------------------------------------------- main window
function script.windowMain(dt)
  if not bgSet then
    ac.setWindowBackground('main', BG, true)
    bgSet = true
  end

  local sim = ac.getSim()
  local me = sim and ac.getCar(0) or nil
  if not sim or not me then
    ui.text('No player car')
    return
  end
  collect(sim, me)

  local origin = ui.getCursor()
  local size = ui.availableSpace()
  local x0, w = origin.x, size.x
  local y, bottom = origin.y, origin.y + size.y

  -- header: "<N> in session · <M> within <nearM> m"
  ui.pushFont(ui.Font.Small)
  tp:set(x0, y)
  ui.drawText(headerText(cfg.nearM), tp, C_HEADER)
  ui.popFont()
  y = y + LINE_H

  -- columns are anchored to the right edge; narrow windows drop speed, then status, then distance
  local showSpeed = cfg.showSpeed and w >= 240
  local showStatus = w >= 170
  local showDist = w >= 110
  local right = x0 + w
  local statusX = showStatus and (right - STATUS_W) or right
  local speedX = showSpeed and (statusX - SPEED_W) or statusX
  local distX = showDist and (speedX - DIST_W) or speedX
  local nameX = x0 + NAME_X
  local nameW = math.max(0, distX - COL_GAP - nameX)

  -- how many rows fit: cfg.maxRows first, then the window height, keeping a line for "+K more"
  local avail = bottom - y
  local limit = math.min(n, math.max(0, math.floor(cfg.maxRows + 0.5)))
  local more = n - limit
  local fits = math.floor(avail / ROW_H)
  if fits < limit then
    limit = math.max(fits, 0)
    more = n - limit
  end
  local showMore = false
  if more > 0 then
    local fitsWithMore = math.floor((avail - LINE_H) / ROW_H)
    if fitsWithMore >= limit then
      showMore = true
    elseif fitsWithMore >= 1 then
      limit = fitsWithMore
      more = n - limit
      showMore = true
    end
  end

  ui.pushFont(ui.Font.Main)
  for k = 1, limit do
    local r = active[k]
    local col = STATUS_COLOR[r.status]
    -- thin status-coloured bar on the left of the row
    pA:set(x0, y + 2)
    pB:set(x0 + BAR_W, y + ROW_H - 2)
    ui.drawRectFilled(pA, pB, col, 1)
    tp:set(x0 + ARROW_X, y)
    ui.drawText(r.arrow, tp, col)
    if nameW > 0 then
      tp:set(nameX, y)
      ui.drawText(displayName(r.idx, nameW), tp, C_TEXT)
    end
    if showDist then
      tp:set(distX, y)
      ui.drawText(distText(r), tp, C_DIM)
    end
    if showSpeed then
      tp:set(speedX, y)
      ui.drawText(speedText(r), tp, C_DIM)
    end
    if showStatus then
      tp:set(statusX, y)
      ui.drawText(STATUS_TEXT[r.status], tp, col)
    end
    y = y + ROW_H
  end
  ui.popFont()

  if n == 0 and y + LINE_H <= bottom then
    ui.pushFont(ui.Font.Small)
    tp:set(x0 + ARROW_X, y)
    ui.drawText('nobody else in the session', tp, C_DIM)
    ui.popFont()
    y = y + LINE_H
  elseif showMore then
    ui.pushFont(ui.Font.Small)
    tp:set(x0 + ARROW_X, y)
    ui.drawText(moreText(more), tp, C_DIM)
    ui.popFont()
    y = y + LINE_H
  end

  -- hand the height we painted back to the layout so the window's content size stays sane
  ui.offsetCursorY(y - origin.y)
end

-- ---------------------------------------------------------------- settings window
function script.windowSettings(dt)
  ui.pushFont(ui.Font.Small)
  ui.text('Who to list')
  ui.popFont()
  if ui.checkbox('Include AI cars (offline sessions)', cfg.includeAI) then cfg.includeAI = not cfg.includeAI end
  if ui.checkbox('Show speed', cfg.showSpeed) then cfg.showSpeed = not cfg.showSpeed end

  ui.separator()
  ui.pushFont(ui.Font.Small)
  ui.text('Distances')
  ui.popFont()
  -- sliders return floats; round so the thresholds stay whole metres
  cfg.nearM = math.floor(ui.slider('##nearM', cfg.nearM, 20, 1000, '"With you" under %.0f m') + 0.5)
  cfg.dropM = math.floor(ui.slider('##dropM', cfg.dropM, 100, 10000, '"Dropped" over %.0f m') + 0.5)
  if cfg.dropM < cfg.nearM then cfg.dropM = cfg.nearM end

  ui.separator()
  cfg.maxRows = math.floor(ui.slider('##maxRows', cfg.maxRows, 1, 30, 'Max rows: %.0f') + 0.5)
end
