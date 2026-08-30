--[[
  Gear Speedo - a small dashboard for Assetto Corsa (Custom Shaders Patch).

  Big gear indicator, road speed, and an 18-segment RPM bar with shift lights.

  The whole layout is derived from the current window size, so dragging the
  window edge scales everything together - no scale setting needed.
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
  shiftAt = 95,
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
  -- ac.getCar can be nil for a frame or two while a session loads.
  local car = ac.getCar(0)
  if not car then return end

  local size = ui.windowSize()
  local s = math.min(size.x / BASE_W, size.y / BASE_H)
  if s <= 0 then return end
  local ox = (size.x - BASE_W * s) / 2
  local oy = (size.y - BASE_H * s) / 2
  local function P(x, y) return vec2(ox + x * s, oy + y * s) end

  -- The rev limit comes straight from the sim here. (The Python build of this
  -- app has to infer it from the limiter flag, because the Python API has no
  -- equivalent of rpmLimiter.)
  local limit = car.rpmLimiter
  if limit == nil or limit <= 0 then limit = math.max(car.rpm, 1000) end

  local frac = clamp01(car.rpm / limit)
  local shift = car.rpm >= limit * (settings.shiftAt / 100)

  blink = (blink + dt) % BLINK_PERIOD
  local flash = shift and blink < BLINK_PERIOD / 2

  -- RPM bar
  local segW = (BAR_W - (SEGMENTS - 1) * SEG_GAP) / SEGMENTS
  local lit = math.floor(frac * SEGMENTS + 1e-4)
  for i = 0, SEGMENTS - 1 do
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

  if ui.checkbox('Use MPH', settings.mph) then
    settings.mph = not settings.mph
  end

  ui.setNextItemWidth(180)
  local v = ui.slider('##shiftAt', settings.shiftAt, 80, 100, 'Shift light: %.0f%%')
  if ui.itemEdited() then
    settings.shiftAt = v
  end

  ui.text('Drag the window edge to resize.')
end
