--[[
  Gear Speedo - a small dashboard for Assetto Corsa (Custom Shaders Patch).

  Big gear indicator, road speed, and an 18-segment RPM bar with shift lights.

  The whole layout is derived from the current window size, so dragging the
  window edge scales everything together - no scale setting needed.

  The title bar is CSP's business: manifest.ini asks for FLOATING_TITLE_BAR,
  which keeps it hidden until the mouse is over the window. CSP has no call
  to change that at runtime; the script only reads the manifest back so the
  settings window can say which title bar the player actually has.
]]

local BASE_W, BASE_H = 280, 120   -- design size; all coordinates are in these units
local SEGMENTS = 18
local SEG_GAP = 2
local BAR_X, BAR_W = 14, 252
local BAR_Y, BAR_Y2 = 10, 22

-- Fractions of the rev limit where the bar changes colour. Red has to start
-- well below the shift point or the white flash covers it before it is seen.
local GREEN_UNTIL, AMBER_UNTIL = 0.55, 0.78
local BLINK_PERIOD = 0.22

local COL_TRACK = rgbm(1, 1, 1, 0.10)
local COL_GREEN = rgbm(0.35, 0.85, 0.42, 1)
local COL_AMBER = rgbm(0.98, 0.75, 0.16, 1)
local COL_RED   = rgbm(0.95, 0.24, 0.24, 1)
local COL_FLASH = rgbm(1, 1, 1, 1)
local COL_TEXT  = rgbm(0.94, 0.95, 0.97, 1)
local COL_DIM   = rgbm(0.55, 0.58, 0.64, 1)
local COL_DIV   = rgbm(1, 1, 1, 0.12)

local settings = ac.storage{
  mph = false,
  showSpeed = true,
  showBar = true,    -- the 18-segment rev bar along the top
  shiftAt = 95,
  opacity = 70,      -- background, percent. The window has NO_BACKGROUND in
                     -- its manifest so this is the only fill behind the HUD.
  lockPos = false,   -- pin the window where it is; -1 means "not captured yet"
  lockX = -1, lockY = -1, lockW = -1, lockH = -1,
}

-- Position lock. CSP has no manifest flag for this, so the app does it
-- itself: while locked it remembers where the window sits and, if anything
-- nudges it, moves it straight back via the window accessor. Everything is
-- pcall-guarded and falls back to doing nothing: the accessor's move/resize
-- need CSP 0.2.3-preview62+, and the name CSP registers the window under is
-- taken from a short list of likely candidates.
local ownWindow, ownWindowRetry = nil, 0
local function findOwnWindow()
  if ownWindow then return ownWindow end
  if ownWindowRetry > 0 then ownWindowRetry = ownWindowRetry - 1; return nil end
  ownWindowRetry = 120                      -- try again in ~2 s if not found
  if type(ac.accessAppWindow) ~= 'function' then return nil end
  for _, name in ipairs({ 'Gear Speedo', 'GearSpeedo', 'GearSpeedo.main', 'GearSpeedo:main' }) do
    local ok, a = pcall(ac.accessAppWindow, name)
    if ok and a ~= nil then
      local okv, valid = pcall(function() return a:valid() end)
      if okv and valid then ownWindow = a; return a end
    end
  end
  return nil
end

local function enforceLock()
  if not settings.lockPos then return end
  local w = findOwnWindow()
  if not w then return end
  pcall(function()
    local p, sz = w:position(), w:size()
    if settings.lockX < 0 then
      -- First frame after locking: this is the spot to hold.
      settings.lockX, settings.lockY = p.x, p.y
      settings.lockW, settings.lockH = sz.x, sz.y
      return
    end
    if math.abs(p.x - settings.lockX) > 0.5 or math.abs(p.y - settings.lockY) > 0.5 then
      w:move(vec2(settings.lockX, settings.lockY))
    end
    if math.abs(sz.x - settings.lockW) > 0.5 or math.abs(sz.y - settings.lockH) > 0.5 then
      w:resize(vec2(settings.lockW, settings.lockH))
    end
  end)
end

-- Which title bar the installed manifest asks for, so the settings window
-- describes what the player is looking at rather than assuming the default.
-- Read once, fully guarded (CSP's own WebBrowser app reads its manifest the
-- same way); on a build without ac.INIConfig the text just stays generic.
local titleBarMode = nil   -- 'hover' | 'always' | 'none' | nil when unknown
pcall(function()
  local ini = ac.INIConfig.load(__dirname .. '/manifest.ini', ac.INIFormat.Extended)
  for name, section in pairs(ini.sections) do
    -- CSP may keep the section as WINDOW_... or number it WINDOW_0; either way
    -- the first window section is the one with our FLAGS line.
    if tostring(name):sub(1, 6) == 'WINDOW' then
      local flags = section.FLAGS
      if type(flags) == 'table' then flags = table.concat(flags, ',') end
      flags = tostring(flags or '')
      if flags:find('NO_TITLE_BAR', 1, true) then titleBarMode = 'none'
      elseif flags:find('FLOATING_TITLE_BAR', 1, true) then titleBarMode = 'hover'
      else titleBarMode = 'always' end
      break
    end
  end
end)

local TITLE_BAR_TEXT = {
  hover  = 'Title bar: hidden until the mouse is over the window (FLAGS in manifest.ini).',
  always = 'Title bar: always shown. Add FLOATING_TITLE_BAR to FLAGS in manifest.ini to hide it until hovered.',
  none   = 'Title bar: none (NO_TITLE_BAR in manifest.ini).',
}

local blink = 0

-- CSP reports gear directly: negative is reverse, 0 is neutral, 1+ is the
-- gear itself. (Note this is NOT the AC Python convention, which is offset
-- by one -- there 0 is reverse and 2 is first.)
local function gearLabel(g)
  if g < 0 then return 'R' end
  if g == 0 then return 'N' end
  return tostring(g)
end

local function clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

function script.windowMain(dt)
  -- Our own background first, at the chosen opacity, before anything else.
  local size = ui.windowSize()
  ui.drawRectFilled(vec2(0, 0), size, rgbm(0, 0, 0, settings.opacity / 100), 4)

  enforceLock()

  -- ac.getCar can be nil for a frame or two while a session loads.
  local car = ac.getCar(0)
  if not car then return end

  local s = math.min(size.x / BASE_W, size.y / BASE_H)
  if s <= 0 then return end
  local ox = (size.x - BASE_W * s) / 2
  local oy = (size.y - BASE_H * s) / 2
  local function P(x, y) return vec2(ox + x * s, oy + y * s) end

  -- The rev limit comes straight from the sim here. (The Python build of this
  -- app has to infer it from the limiter flag, because the Python API has no
  -- equivalent of rpmLimiter.)
  local limit = car.rpmLimiter
  if not (limit and limit > 0) then limit = math.max(car.rpm, 1000) end  -- nil, 0, negative or NaN

  local frac = clamp01(car.rpm / limit)
  local shift = car.rpm >= limit * (settings.shiftAt / 100)

  blink = (blink + dt) % BLINK_PERIOD
  local flash = shift and blink < BLINK_PERIOD / 2

  -- RPM bar
  local segW = (BAR_W - (SEGMENTS - 1) * SEG_GAP) / SEGMENTS
  local lit = math.floor(frac * SEGMENTS + 1e-4)
  for i = 0, (settings.showBar and SEGMENTS - 1 or -1) do
    local x = BAR_X + i * (segW + SEG_GAP)
    local col
    if i >= lit then
      col = COL_TRACK
    elseif flash then
      col = COL_FLASH
    else
      local pos = (i + 1) / SEGMENTS
      if pos <= GREEN_UNTIL then col = COL_GREEN
      elseif pos <= AMBER_UNTIL then col = COL_AMBER
      else col = COL_RED end
    end
    ui.drawRectFilled(P(x, BAR_Y), P(x + segW, BAR_Y2), col)
  end

  ui.pushDWriteFont('@System;Weight=Bold')

  local gearCx = settings.showSpeed and 70 or BASE_W / 2
  ui.dwriteDrawTextClipped(gearLabel(car.gear), 58 * s,
    P(gearCx - 60, 24), P(gearCx + 60, 90),
    ui.Alignment.Center, ui.Alignment.Center, false,
    shift and COL_RED or COL_TEXT)
  ui.dwriteDrawTextClipped('GEAR', 10 * s,
    P(gearCx - 60, 90), P(gearCx + 60, 106),
    ui.Alignment.Center, ui.Alignment.Center, false, COL_DIM)

  if settings.showSpeed then
    ui.drawRectFilled(P(139, 34), P(140, 86), COL_DIV)

    local speed = settings.mph and car.speedKmh * 0.621371 or car.speedKmh
    if speed < 0 then speed = 0 end
    ui.dwriteDrawTextClipped(tostring(math.floor(speed)), 44 * s,
      P(136, 34), P(256, 90),
      ui.Alignment.Center, ui.Alignment.Center, false, COL_TEXT)
    ui.dwriteDrawTextClipped(settings.mph and 'MPH' or 'KM/H', 10 * s,
      P(136, 90), P(256, 106),
      ui.Alignment.Center, ui.Alignment.Center, false, COL_DIM)
  end

  ui.popDWriteFont()
end

function script.windowSettings(dt)
  if ui.checkbox('Show speed', settings.showSpeed) then
    settings.showSpeed = not settings.showSpeed
  end

  if ui.checkbox('Show RPM bar', settings.showBar) then
    settings.showBar = not settings.showBar
  end

  if ui.checkbox('Lock position and size', settings.lockPos) then
    settings.lockPos = not settings.lockPos
    -- Capture afresh at the next frame so it holds wherever it is right now.
    settings.lockX, settings.lockY, settings.lockW, settings.lockH = -1, -1, -1, -1
  end
  if settings.lockPos then
    ui.text('Locked where it is. Untick to move or resize it.')
  end

  if ui.checkbox('Use MPH', settings.mph) then
    settings.mph = not settings.mph
  end

  ui.setNextItemWidth(180)
  local v = ui.slider('##shiftAt', settings.shiftAt, 80, 100, 'Shift light: %.0f%%')
  if ui.itemEdited() then
    settings.shiftAt = v
  end

  ui.setNextItemWidth(180)
  local o = ui.slider('##opacity', settings.opacity, 0, 100, 'Background: %.0f%%')
  if ui.itemEdited() then
    settings.opacity = o
  end

  ui.text('Drag the window edge to resize.')
  ui.text(TITLE_BAR_TEXT[titleBarMode] or 'Title bar: set by the FLAGS line in manifest.ini.')
end
