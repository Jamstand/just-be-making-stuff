-- JamPure Cruise Cluster — a road-car dash for highway cruising, not a race HUD.
-- Left: big speed with the unit under it. Centre: gear glyph over an rpm bar with a red zone.
-- Right: fuel gauge with litres left, an estimated range from measured consumption, trip and odometer.
-- Bottom: indicator strip (low/high beam, turn signals, handbrake, ABS/TC, clock).
-- Target: CSP 0.2.11+ / 0.3.0 previews. Single file, no requires; the only global is `script`.

script = script or {}

-- ---------------------------------------------------------------- settings (persistent, edited in windowSettings)
local cfg = ac.storage{
  mph = false,        -- speed, range, trip and odo in miles instead of km
  showTemps = false,  -- small water / oil temperature line in the right column
  accent = 1,         -- 1 white, 2 amber, 3 cyan: colour of the speed, gear and fuel fill
  rpmBarH = 10,       -- rpm bar height in px (4..24)
}

-- ---------------------------------------------------------------- constants
local PAD = 8                 -- inner margin of the panel
local PANEL_R = 8             -- panel corner radius
local STRIP_H = 26            -- indicator strip height
local LINE_H = 14             -- line pitch for ui.Font.Small
local TITLE_H = 24            -- line pitch for ui.Font.Title
local HUGE_H = 40             -- approximate glyph height of ui.Font.Huge (fallback when DirectWrite is missing)
local GAP = 6                 -- spacing between indicators
local KM_TO_MI = 0.621371
local RED_ZONE = 0.12         -- top 12% of the limiter is the red zone
local BLINK_HZ = 1.5          -- turn signal blink rate
local SAMPLE_KM = 0.5         -- consumption sample spacing
local MAX_SAMPLES = 6         -- ring buffer size for consumption samples

-- DirectWrite text scales to any size; fall back to the bitmap fonts if the build lacks it.
local hasDWrite = type(ui.dwriteDrawText) == 'function' and type(ui.measureDWriteText) == 'function'

-- ---------------------------------------------------------------- colours (allocated once)
local C_PANEL = rgbm(0.06, 0.06, 0.07, 0.86)
local C_TEXT = rgbm(0.92, 0.92, 0.92, 1)
local C_DIM = rgbm(0.60, 0.60, 0.63, 1)
local C_OFF = rgbm(0.27, 0.27, 0.30, 1)     -- inactive indicators
local C_BAR_BG = rgbm(0.16, 0.16, 0.18, 1)
local C_LINE = rgbm(0.22, 0.22, 0.25, 1)
local C_RED = rgbm(0.95, 0.20, 0.16, 1)
local C_REDZONE = rgbm(0.75, 0.12, 0.10, 0.55)
local C_AMBER = rgbm(1.00, 0.68, 0.12, 1)
local C_GREEN = rgbm(0.30, 0.90, 0.40, 1)
local C_BLUE = rgbm(0.35, 0.58, 1.00, 1)
local C_CLEAR = rgbm(0, 0, 0, 0)
local ACCENTS = { rgbm(1, 1, 1, 1), rgbm(1, 0.72, 0.20, 1), rgbm(0.35, 0.90, 1, 1) }
local ACCENT_FMT = { 'Accent %.0f: white', 'Accent %.0f: amber', 'Accent %.0f: cyan' }
local rpmFill = rgbm(1, 1, 1, 1)             -- recoloured in place every frame

-- scratch vectors reused every frame so the draw code does not allocate
local pA, pB, pC, tp = vec2(), vec2(), vec2(), vec2()

-- gear glyphs; anything above 8 is added on first use
local GEAR = { [-1] = 'R', [0] = 'N', '1', '2', '3', '4', '5', '6', '7', '8' }

-- ---------------------------------------------------------------- cached strings (re-formatted only when the rounded value changes)
local speedKey, speedStr = -1, '0'
local fuelKey, fuelStr = -1, '--'
local rangeKey, rangeStr = -1, 'range --'
local tripKey, tripStr = -1, 'trip 0.0 km'
local odoKey, odoStr = -1, 'odo 0 km'
local tripOdoStr, tripOdoW = '', 0
local clockKey, clockStr, clockW = -1, '--:--', 0
local tempKey, tempStr = -1, ''
local gearKey, gearW = -1, 0
local speedW = 0
local absStr, tcStr = {}, {}   -- "ABS 1", "TC 2" ...
local bgSet = false
local tcField = nil            -- resolved on first frame: 'tractionControlMode' (SDK) or 'tcMode'

local function speedText(car, mph)
  local v = car.speedKmh or 0
  if mph then v = v * KM_TO_MI end
  local key = math.floor(v + 0.5)
  if key ~= speedKey then
    speedKey = key
    speedStr = string.format('%d', key)
    speedW = -1   -- re-measure
  end
  return speedStr
end

local function fuelText(car)
  local key = math.floor((car.fuel or 0) * 10 + 0.5)
  if key ~= fuelKey then
    fuelKey = key
    fuelStr = string.format('%.1f L', key / 10)
  end
  return fuelStr
end

local function rangeText(rangeKm, mph)
  local key
  if rangeKm <= 0 then
    key = -1
  else
    key = math.floor((mph and rangeKm * KM_TO_MI or rangeKm) + 0.5)
    if mph then key = key + 1000000 end   -- unit change must refresh the string too
  end
  if key ~= rangeKey then
    rangeKey = key
    if key < 0 then
      rangeStr = 'range --'
    elseif mph then
      rangeStr = string.format('range %d mi', key - 1000000)
    else
      rangeStr = string.format('range %d km', key)
    end
  end
  return rangeStr
end

-- trip and odo: trip to a tenth, odo whole; returns true when either string changed
local function tripOdoText(car, mph)
  local trip = car.distanceDrivenSessionKm or 0
  local odo = car.distanceDrivenTotalKm or 0
  if mph then trip, odo = trip * KM_TO_MI, odo * KM_TO_MI end
  local tk = math.floor(trip * 10 + 0.5) + (mph and 100000000 or 0)
  local ok = math.floor(odo + 0.5) + (mph and 100000000 or 0)
  local changed = false
  if tk ~= tripKey then
    tripKey = tk
    tripStr = string.format(mph and 'trip %.1f mi' or 'trip %.1f km', (tk % 100000000) / 10)
    changed = true
  end
  if ok ~= odoKey then
    odoKey = ok
    odoStr = string.format(mph and 'odo %d mi' or 'odo %d km', ok % 100000000)
    changed = true
  end
  if changed then tripOdoStr = tripStr .. ' · ' .. odoStr end
  return changed
end

local function clockText(sim)
  local t = sim.timeHours
  if t == nil then return clockStr end
  local h = math.floor(t) % 24
  local m = math.floor((t - math.floor(t)) * 60) % 60
  local key = h * 60 + m
  if key ~= clockKey then
    clockKey = key
    clockStr = string.format('%02d:%02d', h, m)
    clockW = -1
  end
  return clockStr
end

local function tempText(car)
  local w = math.floor((car.waterTemperature or 0) + 0.5)
  local o = math.floor((car.oilTemperature or 0) + 0.5)
  local key = w * 1000 + o
  if key ~= tempKey then
    tempKey = key
    tempStr = string.format('W %d°  O %d°', w, o)
  end
  return tempStr
end

local function modeLabel(cache, prefix, mode)
  local s = cache[mode]
  if not s then
    s = mode > 0 and string.format('%s %d', prefix, mode) or prefix
    cache[mode] = s
  end
  return s
end

local function textWidth(s)
  local m = ui.measureText(s)
  return m and m.x or (#s * 7)
end

-- widths of the small fixed strip labels ("P", "ABS 2", "TC 1"), measured once under ui.Font.Small
local smallW = {}
local function smallWidth(s)
  local w = smallW[s]
  if not w then
    w = textWidth(s)
    smallW[s] = w
  end
  return w
end

-- ---------------------------------------------------------------- range estimate
-- One (km, fuel) sample every SAMPLE_KM driven, kept in a ring of MAX_SAMPLES; litres per km is
-- (oldest.fuel - newest.fuel) / (newest.km - oldest.km). A refuel or a session reset clears the ring.
local samples = {}
for i = 1, MAX_SAMPLES do samples[i] = { km = 0, fuel = 0 } end
local sampleCount, sampleHead = 0, 0
local lastSampleKm = -1e9

local function updateRange(car, sim)
  local km = car.distanceDrivenSessionKm or 0
  local fuel = car.fuel or 0
  if sampleCount > 0 then
    local newest = samples[sampleHead]
    if km < newest.km - 0.01 or fuel > newest.fuel + 0.3 then
      sampleCount, lastSampleKm = 0, -1e9
    end
  end
  if km - lastSampleKm >= SAMPLE_KM then
    sampleHead = sampleHead % MAX_SAMPLES + 1
    local s = samples[sampleHead]
    s.km, s.fuel = km, fuel
    if sampleCount < MAX_SAMPLES then sampleCount = sampleCount + 1 end
    lastSampleKm = km
  end

  local lPerKm = 0
  if sampleCount >= 2 then
    local o = samples[(sampleHead - sampleCount) % MAX_SAMPLES + 1]
    local n = samples[sampleHead]
    local dKm, dFuel = n.km - o.km, o.fuel - n.fuel
    if dKm > 0.1 and dFuel > 0 then lPerKm = dFuel / dKm end
  end
  -- not enough driving yet: fall back to the sim's per-lap figure scaled by track length
  if lPerKm <= 0 then
    local fpl = car.fuelPerLap or 0
    local trackKm = (sim.trackLengthM or 0) / 1000
    if fpl > 0 and trackKm > 0 then lPerKm = fpl / trackKm end
  end
  if lPerKm <= 0 then return 0 end
  return fuel / lPerKm
end

-- ---------------------------------------------------------------- rpm bar colour
-- White up to 60%, white → amber up to the red zone, amber → red inside it.
local function setRpmColour(f)
  local redStart = 1 - RED_ZONE
  if f < 0.6 then
    rpmFill:set(1, 1, 1, 1)
  elseif f < redStart then
    local t = (f - 0.6) / (redStart - 0.6)
    rpmFill:set(1, 1 - 0.32 * t, 1 - 0.88 * t, 1)
  else
    local t = math.saturate((f - redStart) / RED_ZONE)
    rpmFill:set(1 - 0.05 * t, 0.68 - 0.48 * t, 0.12 + 0.04 * t, 1)
  end
end

-- ---------------------------------------------------------------- indicator glyphs
-- Headlamp: a filled disc with three beam lines to the left. Low beams tilt down, high beams run level.
local function drawBeamIcon(x, y, h, col, high)
  local r = h * 0.30
  local cx, cy = x + h * 0.95, y + h * 0.5
  pA:set(cx, cy)
  ui.drawCircleFilled(pA, r, col, 12)
  local len = h * 0.55
  for k = -1, 1 do
    local yy = cy + k * r * 0.75
    pA:set(cx - r - 2, yy)
    pB:set(cx - r - 2 - len, high and yy or (yy + h * 0.16))
    ui.drawLine(pA, pB, col, 1.5)
  end
end

local function drawArrow(x, y, w, h, col, left)
  if left then
    pA:set(x, y + h * 0.5); pB:set(x + w, y); pC:set(x + w, y + h)
  else
    pA:set(x + w, y + h * 0.5); pB:set(x, y); pC:set(x, y + h)
  end
  ui.drawTriangleFilled(pA, pB, pC, col)
end

-- The real SDK names the field tractionControlMode; the brief calls it tcMode. Probe once with pcall so a
-- missing struct member can never throw every frame.
local function probeTcField(car)
  local ok, v = pcall(function() return car.tractionControlMode end)
  if ok and v ~= nil then return 'tractionControlMode' end
  ok, v = pcall(function() return car.tcMode end)
  if ok and v ~= nil then return 'tcMode' end
  return false
end

-- ---------------------------------------------------------------- main window
function script.windowMain(dt)
  if not bgSet then
    -- the rounded panel below is the visible background, so the window itself stays clear
    ac.setWindowBackground('main', C_CLEAR, true)
    bgSet = true
  end

  local origin = ui.getCursor()
  local size = ui.availableSpace()
  local x0, y0 = origin.x, origin.y
  local w, h = math.max(size.x, 0), math.max(size.y, 0)

  pA:set(x0, y0); pB:set(x0 + w, y0 + h)
  ui.drawRectFilled(pA, pB, C_PANEL, PANEL_R)

  local sim = ac.getSim()
  local car = sim and ac.getCar(0) or nil
  if not sim or not car then
    tp:set(x0 + PAD, y0 + PAD)
    ui.drawText('No player car', tp, C_DIM)
    ui.offsetCursorY(h)
    return
  end
  if tcField == nil then tcField = probeTcField(car) end

  local mph = cfg.mph == true
  local accent = ACCENTS[math.clamp(math.floor(cfg.accent + 0.5), 1, 3)]
  local stripH = math.min(STRIP_H, h * 0.25)
  local bodyH = h - stripH
  local leftW = w * 0.34
  local midW = w * 0.28
  local rightW = w - leftW - midW
  local midX, rightX = x0 + leftW, x0 + leftW + midW

  -- ------------------------------------------------ left: speed
  local sStr = speedText(car, mph)
  local speedSize = math.clamp(math.floor(math.min(64, (leftW - PAD) / 1.7, bodyH * 0.55)), 10, 64)
  local unitY
  if hasDWrite then
    local blockH = speedSize * 1.05 + LINE_H
    local sy = y0 + math.max(2, (bodyH - blockH) * 0.5)
    tp:set(x0 + PAD, sy)
    ui.dwriteDrawText(sStr, speedSize, tp, accent)
    unitY = sy + speedSize * 1.05
  else
    local blockH = HUGE_H + LINE_H
    local sy = y0 + math.max(2, (bodyH - blockH) * 0.5)
    ui.pushFont(ui.Font.Huge)
    tp:set(x0 + PAD, sy)
    ui.drawText(sStr, tp, accent)
    ui.popFont()
    unitY = sy + HUGE_H
  end
  ui.pushFont(ui.Font.Small)
  tp:set(x0 + PAD + 2, unitY)
  ui.drawText(mph and 'mph' or 'km/h', tp, C_DIM)
  ui.popFont()

  -- ------------------------------------------------ centre: gear glyph over the rpm bar
  local rpmH = math.clamp(math.floor(cfg.rpmBarH + 0.5), 4, 24)
  local barY = y0 + bodyH - PAD - rpmH
  local gear = car.gear or 0
  local gStr = GEAR[gear]
  if not gStr then gStr = tostring(gear); GEAR[gear] = gStr end
  local gearSize = math.clamp(math.floor(math.min(56, bodyH - rpmH - PAD * 2, midW * 0.9)), 10, 56)
  local gearArea = barY - PAD * 0.5 - y0
  if hasDWrite then
    local key = gear * 100 + gearSize
    if key ~= gearKey then   -- measure only when the glyph or its size changes
      gearKey = key
      local m = ui.measureDWriteText(gStr, gearSize)
      gearW = m and m.x or gearSize * 0.6
    end
    tp:set(midX + (midW - gearW) * 0.5, y0 + math.max(0, (gearArea - gearSize * 1.1) * 0.5))
    ui.dwriteDrawText(gStr, gearSize, tp, accent)
  else
    ui.pushFont(ui.Font.Huge)
    tp:set(midX + (midW - textWidth(gStr)) * 0.5, y0 + math.max(0, (gearArea - HUGE_H) * 0.5))
    ui.drawText(gStr, tp, accent)
    ui.popFont()
  end

  local bx0, bx1 = midX + PAD * 0.5, midX + midW - PAD * 0.5
  local bw = math.max(bx1 - bx0, 1)
  pA:set(bx0, barY); pB:set(bx1, barY + rpmH)
  ui.drawRectFilled(pA, pB, C_BAR_BG, 2)
  pA:set(bx0 + bw * (1 - RED_ZONE), barY)
  ui.drawRectFilled(pA, pB, C_REDZONE, 2)
  local lim = car.rpmLimiter or 0
  local f = lim > 0 and math.saturate((car.rpm or 0) / lim) or 0
  if f > 0 then
    setRpmColour(f)
    pA:set(bx0, barY); pB:set(bx0 + bw * f, barY + rpmH)
    ui.drawRectFilled(pA, pB, rpmFill, 2)
  end

  -- ------------------------------------------------ right: fuel gauge, range, trip / odo
  local gaugeW = 12
  local gx1 = x0 + w - PAD
  local gx0 = gx1 - gaugeW
  local gy0, gy1 = y0 + PAD, y0 + bodyH - PAD
  local maxFuel = car.maxFuel or 0
  local ff = maxFuel > 0 and math.saturate((car.fuel or 0) / maxFuel) or 0
  local fuelCol = ff < 0.10 and C_RED or (ff < 0.25 and C_AMBER or accent)
  pA:set(gx0, gy0); pB:set(gx1, gy1)
  ui.drawRectFilled(pA, pB, C_BAR_BG, 3)
  if ff > 0 then
    pA:set(gx0, gy1 - (gy1 - gy0) * ff)
    ui.drawRectFilled(pA, pB, fuelCol, 3)
  end
  for k = 1, 3 do   -- quarter ticks
    local ty = gy1 - (gy1 - gy0) * k / 4
    pA:set(gx0 - 4, ty); pB:set(gx0 - 1, ty)
    ui.drawLine(pA, pB, C_DIM, 1)
  end

  local rangeKm = updateRange(car, sim)
  local rStr = rangeText(rangeKm, mph)
  local tx = rightX + PAD * 0.5
  local textW = gx0 - 6 - tx
  local showTemps = cfg.showTemps == true
  ui.pushFont(ui.Font.Small)
  if tripOdoText(car, mph) or tripOdoW <= 0 then tripOdoW = textWidth(tripOdoStr) end
  local oneLine = tripOdoW <= textW
  local blockH = TITLE_H + LINE_H + (oneLine and LINE_H or LINE_H * 2) + (showTemps and LINE_H or 0)
  local ty = y0 + math.max(PAD * 0.5, (bodyH - blockH) * 0.5)
  ui.popFont()

  ui.pushFont(ui.Font.Title)
  tp:set(tx, ty)
  ui.drawText(fuelText(car), tp, ff < 0.10 and C_RED or C_TEXT)
  ui.popFont()
  ty = ty + TITLE_H

  ui.pushFont(ui.Font.Small)
  tp:set(tx, ty)
  ui.drawText(rStr, tp, C_DIM)
  ty = ty + LINE_H
  if oneLine then
    tp:set(tx, ty)
    ui.drawText(tripOdoStr, tp, C_DIM)
    ty = ty + LINE_H
  else
    tp:set(tx, ty)
    ui.drawText(tripStr, tp, C_DIM)
    ty = ty + LINE_H
    tp:set(tx, ty)
    ui.drawText(odoStr, tp, C_DIM)
    ty = ty + LINE_H
  end
  if showTemps then
    tp:set(tx, ty)
    ui.drawText(tempText(car), tp, C_DIM)
  end
  ui.popFont()

  -- ------------------------------------------------ bottom: indicator strip
  local sy = y0 + bodyH
  pA:set(x0 + PAD, sy); pB:set(x0 + w - PAD, sy)
  ui.drawLine(pA, pB, C_LINE, 1)
  local ih = math.max(stripH - 10, 4)      -- icon height
  local iy = sy + (stripH - ih) * 0.5
  local textY = sy + (stripH - LINE_H) * 0.5
  local ix = x0 + PAD

  ui.pushFont(ui.Font.Small)
  local cStr = clockText(sim)
  if clockW <= 0 then clockW = textWidth(cStr) end
  local clkX = x0 + w - PAD - clockW
  tp:set(clkX, textY)
  ui.drawText(cStr, tp, C_TEXT)
  local limitX = clkX - GAP

  -- blink phase shared by both arrows: 1.5 Hz square wave
  local blinkOn = (os.preciseClock() * BLINK_HZ) % 1 < 0.5
  local hazard = car.hazardLights == true
  -- headlightsActive is the switch; highBeams picks which lamp lights (lowBeams may be a mode flag that
  -- stays set with the lights off, so it is not trusted on its own)
  local lightsOn = car.headlightsActive == true
  local highOn = lightsOn and car.highBeams == true
  local lowOn = lightsOn and not highOn

  local iw = ih * 1.6
  if ix + iw <= limitX then
    drawBeamIcon(ix, iy, ih, lowOn and C_GREEN or C_OFF, false)
    ix = ix + iw + GAP
  end
  if ix + iw <= limitX then
    drawBeamIcon(ix, iy, ih, highOn and C_BLUE or C_OFF, true)
    ix = ix + iw + GAP
  end
  local aw = ih * 0.9
  if ix + aw * 2 + 3 <= limitX then
    local leftOn = (hazard or car.turningLeftLights == true) and blinkOn
    local rightOn = (hazard or car.turningRightLights == true) and blinkOn
    drawArrow(ix, iy, aw, ih, leftOn and C_AMBER or C_OFF, true)
    ix = ix + aw + 3
    drawArrow(ix, iy, aw, ih, rightOn and C_AMBER or C_OFF, false)
    ix = ix + aw + GAP
  end
  local pw = smallWidth('P')
  if ix + pw <= limitX then
    tp:set(ix, textY)
    ui.drawText('P', tp, (car.handbrake or 0) > 0.5 and C_RED or C_OFF)
    ix = ix + pw + GAP
  end
  local absMode = car.absMode or 0
  local aStr = modeLabel(absStr, 'ABS', absMode)
  local aw2 = smallWidth(aStr)
  if ix + aw2 <= limitX then
    tp:set(ix, textY)
    ui.drawText(aStr, tp, absMode > 0 and C_TEXT or C_OFF)
    ix = ix + aw2 + GAP
  end
  local tcMode = tcField and (car[tcField] or 0) or 0
  local tStr = modeLabel(tcStr, 'TC', tcMode)
  local tw = smallWidth(tStr)
  if ix + tw <= limitX then
    tp:set(ix, textY)
    ui.drawText(tStr, tp, tcMode > 0 and C_TEXT or C_OFF)
  end
  ui.popFont()

  -- hand the painted height back to the layout so the window's content size stays sane
  ui.offsetCursorY(h)
end

-- ---------------------------------------------------------------- settings window
function script.windowSettings(dt)
  ui.pushFont(ui.Font.Small)
  ui.text('Units')
  ui.popFont()
  if ui.checkbox('Speed and distances in mph / miles', cfg.mph) then cfg.mph = not cfg.mph end
  if ui.checkbox('Show water / oil temperature', cfg.showTemps) then cfg.showTemps = not cfg.showTemps end

  ui.separator()
  ui.pushFont(ui.Font.Small)
  ui.text('Look')
  ui.popFont()
  -- sliders return floats; round so the values stay whole
  local accent = math.clamp(math.floor(cfg.accent + 0.5), 1, 3)
  cfg.accent = math.clamp(math.floor(ui.slider('##accent', accent, 1, 3, ACCENT_FMT[accent]) + 0.5), 1, 3)
  cfg.rpmBarH = math.clamp(math.floor(ui.slider('##rpmBarH', cfg.rpmBarH, 4, 24, 'RPM bar height: %.0f px') + 0.5), 4, 24)
end
