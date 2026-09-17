-- JamPure Filter Doctor
-- The diagnostics panel that would have caught the "no Pure script" bug: Pure looks for
-- <ppfilters>/pure_scripts/<filter>.lua (Gamma) or <ppfilters>/purelcs_scripts/<filter>.lua
-- (linear colour space). When the file for the *active* variant is missing, Pure silently
-- falls back to default_script.lua and the filter looks nothing like it should.
-- This app checks the disk every few seconds (not per frame), shows found/missing per variant,
-- a one-line verdict, and the exposure / time / weather / render state that changes the look.

script = script or {}

-- ---------------------------------------------------------------- settings (persisted by CSP)
local cfg = ac.storage{
  refreshSeconds  = 2,      -- how often to re-check the files on disk (0.5..10 s)
  alwaysShowPaths = false,  -- show the expected script paths even when the files are found
}

-- ---------------------------------------------------------------- constants
local DOT_R    = 3.5   -- status dot radius
local LABEL_X  = 12    -- label text starts this far right of the row origin (after the dot)
local MULT_STEP, MULT_MIN, MULT_MAX = 0.05, 0.1, 4

-- Colours. Dots and value text share the same four "meanings".
local COL_OK      = rgbm(0.35, 0.90, 0.40, 1.0)   -- green: present / on
local COL_BAD     = rgbm(1.00, 0.30, 0.30, 1.0)   -- red: missing / off
local COL_WARN    = rgbm(1.00, 0.78, 0.25, 1.0)   -- amber: daylight, attention
local COL_INFO    = rgbm(0.45, 0.72, 1.00, 1.0)   -- blue: night, informational
local COL_NEUTRAL = rgbm(1.00, 1.00, 1.00, 0.35)  -- grey: nothing to say
local COL_LABEL   = rgbm(1.00, 1.00, 1.00, 0.55)
local COL_VALUE   = rgbm.colors.white
local COL_PATH    = rgbm(1.00, 1.00, 1.00, 0.40)
local COL_LEADER  = rgbm(1.00, 1.00, 1.00, 0.12)  -- the faint "....." between label and value
local COL_BAND_OK  = rgbm(0.20, 0.80, 0.30, 0.22)
local COL_BAND_BAD = rgbm(1.00, 0.25, 0.25, 0.22)
local COL_BAND_WARN = rgbm(1.00, 0.70, 0.20, 0.22)

-- ---------------------------------------------------------------- reusable scratch objects (no per-frame allocation)
local pDot   = vec2()
local pText  = vec2()
local pA     = vec2()
local pB     = vec2()
local pCur   = vec2()
local btnSmall = vec2(20, 16)
local btnWide  = vec2(44, 16)

-- ---------------------------------------------------------------- cached diagnostics (refreshed every cfg.refreshSeconds)
local st = {
  lastRefresh = -1e9,
  filter = '',        -- PP filter name as reported by CSP ('' when unknown)
  ppDir = '',
  iniOk = false,
  gammaOk = false,
  lcsOk = false,
  gammaPath = '',     -- full expected paths
  lcsPath = '',
  gammaLine = '',     -- "Gamma: <full path>" lines for the settings window
  lcsLine = '',
  gammaShort = '',    -- shortened, window-fitted versions for the panel
  lcsShort = '',
  nameShort = '',     -- filter name fitted to the header width
  fitW = -1,          -- width the short strings were fitted for
  -- slow-changing text, formatted once per refresh instead of once per frame
  timeSunStr = '', rainStr = '', tempStr = '', renderStr = '', detailStr = '',
  sunNight = false, raining = false,
}

-- Font metrics, measured on the first frame (and re-measured on every refresh in case UI scale changes).
local mainH, smallH, rowH = 14, 12, 17
local metricsOk = false
local bgSet = false

-- ---------------------------------------------------------------- helpers

-- Shortens a path from the left until it fits maxW under the *current* font, e.g. "…ripts/JamPure.lua".
-- Only called on refresh / resize, so the string churn is negligible.
local function fitTail(s, maxW)
  if ui.measureText(s).x <= maxW then return s end
  local n = #s
  while n > 4 do
    n = n - 2
    local candidate = '…' .. s:sub(#s - n + 1)
    if ui.measureText(candidate).x <= maxW then return candidate end
  end
  return s:sub(-4)
end

-- "expected: <path>" when it fits, plain "<path>" when the prefix would push it over, then fitTail.
local function fitPathLine(path, maxW)
  local withPrefix = 'expected: ' .. path
  if ui.measureText(withPrefix).x <= maxW then return withPrefix end
  return fitTail(path, maxW)
end

local function measureFonts()
  ui.pushFont(ui.Font.Small)
  smallH = ui.measureText('Ag').y
  ui.popFont()
  mainH = ui.measureText('Ag').y
  rowH = mainH + 3
  btnSmall:set(math.max(18, mainH + 5), math.max(14, mainH + 1))
  btnWide:set(math.max(40, mainH * 3), math.max(14, mainH + 1))
  metricsOk = true
end

-- Re-fits the header name and the two path strings to the given content width
-- (paths are shown relative to the ppfilters folder: "ppfilters/pure_scripts/<filter>.lua").
local function fitPaths(w)
  st.fitW = w
  local maxW = math.max(20, w - LABEL_X)
  ui.pushFont(ui.Font.Small)
  if st.filter ~= '' then
    st.gammaShort = fitPathLine('ppfilters/pure_scripts/' .. st.filter .. '.lua', maxW)
    st.lcsShort   = fitPathLine('ppfilters/purelcs_scripts/' .. st.filter .. '.lua', maxW)
  else
    st.gammaShort, st.lcsShort = 'no filter name reported', 'no filter name reported'
  end
  ui.popFont()
  ui.pushFont(ui.Font.Title)
  st.nameShort = fitTail(st.filter ~= '' and st.filter or 'no PP filter', maxW)
  ui.popFont()
end

-- The slow part: disk checks + slow-changing strings. Runs every cfg.refreshSeconds, never per frame.
local function refresh(now, sim, w)
  st.lastRefresh = now

  local filter = ac.getPpFilter()
  if type(filter) ~= 'string' then filter = '' end
  filter = filter:gsub('%.ini$', '')          -- be tolerant if a build ever reports "name.ini"
  local ppDir = ac.getFolder(ac.FolderID.PPFilters)
  if type(ppDir) ~= 'string' then ppDir = '' end
  st.filter, st.ppDir = filter, ppDir

  if filter ~= '' and ppDir ~= '' then
    local iniPath = ppDir .. '/' .. filter .. '.ini'
    st.gammaPath = ppDir .. '/pure_scripts/' .. filter .. '.lua'
    st.lcsPath   = ppDir .. '/purelcs_scripts/' .. filter .. '.lua'
    st.iniOk   = io.fileExists(iniPath)
    st.gammaOk = io.fileExists(st.gammaPath)
    st.lcsOk   = io.fileExists(st.lcsPath)
    st.gammaLine = 'Gamma: ' .. st.gammaPath
    st.lcsLine   = 'LCS: ' .. st.lcsPath
  else
    st.gammaPath, st.lcsPath, st.gammaLine, st.lcsLine = '', '', '', ''
    st.iniOk, st.gammaOk, st.lcsOk = false, false, false
  end

  -- Time of day as HH:MM from fractional hours; sun angle in degrees (negative = below horizon).
  local hours = sim.timeHours or 0
  local hh = math.floor(hours) % 24
  local mm = math.floor((hours - math.floor(hours)) * 60 + 0.0001) % 60
  local sun = ac.getSunAngle() or 0
  st.sunNight = sun < 0
  st.timeSunStr = string.format('%02d:%02d · sun %.1f°%s', hh, mm, sun, st.sunNight and ' night' or '')

  local rain = sim.rainIntensity or 0
  st.raining = rain > 0.005
  st.rainStr = string.format('%d%%', math.floor(rain * 100 + 0.5))
  st.tempStr = string.format('%.0f°C air / %.0f°C road', sim.ambientTemperature or 0, sim.roadTemperature or 0)

  local msaa = sim.msaaSamples or 0
  st.renderStr = string.format('LCS %s · FSR %s · %s',
    sim.isLinearColorSpaceActive and 'on' or 'off',
    sim.isFSRActive and 'on' or 'off',
    msaa > 1 and ('MSAA x' .. msaa) or 'MSAA off')
  st.detailStr = string.format('%d / 5 · %dx%d', sim.worldDetailLevel or 0, sim.windowWidth or 0, sim.windowHeight or 0)

  measureFonts()
  fitPaths(w)
end

-- One "label ..... value" row with a status dot. Draws nothing if the row would leave the window,
-- but still advances y so the layout stays stable. Returns the next y. noLeader skips the dotted
-- leader line (used on the row that hosts the exposure buttons).
local function drawRow(label, value, dotCol, valueCol, x, y, w, bottom, noLeader)
  if y + rowH > bottom then return y + rowH end
  local cy = y + rowH * 0.5
  pDot:set(x + DOT_R + 1, cy)
  ui.drawCircleFilled(pDot, DOT_R, dotCol, 12)

  ui.pushFont(ui.Font.Small)
  local lm = ui.measureText(label)
  pText:set(x + LABEL_X, cy - lm.y * 0.5)
  ui.drawText(label, pText, COL_LABEL)
  ui.popFont()

  local vm = ui.measureText(value)
  local labelEnd = x + LABEL_X + lm.x
  local vx = math.max(labelEnd + 6, x + w - vm.x)   -- right-aligned, but never over the label
  pText:set(vx, cy - vm.y * 0.5)
  ui.drawText(value, pText, valueCol or COL_VALUE)

  -- Faint leader line between label and value, only when there is room for it.
  if not noLeader and vx - labelEnd > 14 then
    pA:set(labelEnd + 5, cy + lm.y * 0.35)
    pB:set(vx - 5, cy + lm.y * 0.35)
    ui.drawLine(pA, pB, COL_LEADER, 1)
  end
  return y + rowH
end

-- Small muted line under a row (the expected path). Same clamping rules as drawRow.
local function drawSubLine(text, x, y, bottom)
  local h = smallH + 1
  if y + h > bottom then return y + h end
  ui.pushFont(ui.Font.Small)
  pText:set(x + LABEL_X, y)
  ui.drawText(text, pText, COL_PATH)
  ui.popFont()
  return y + h
end

-- Coloured verdict band. Falls back to the small font when the sentence is wider than the panel.
local function drawVerdict(text, bandCol, textCol, x, y, w, bottom)
  local bandH = mainH + 8
  if y + bandH > bottom then return y + bandH end
  pA:set(x, y); pB:set(x + w, y + bandH)
  ui.drawRectFilled(pA, pB, bandCol, 3)
  local m = ui.measureText(text)
  if m.x <= w - 8 then
    pText:set(x + (w - m.x) * 0.5, y + (bandH - m.y) * 0.5)
    ui.drawText(text, pText, textCol)
  else
    ui.pushFont(ui.Font.Small)
    m = ui.measureText(text)
    pText:set(math.max(x + 4, x + (w - m.x) * 0.5), y + (bandH - m.y) * 0.5)
    ui.drawText(text, pText, textCol)
    ui.popFont()
  end
  return y + bandH + 2
end

-- ---------------------------------------------------------------- main window
function script.windowMain(dt)
  if not bgSet then
    ac.setWindowBackground('main', rgbm(0, 0, 0, 0.55), true)
    bgSet = true
  end
  if not metricsOk then measureFonts() end

  local origin = ui.getCursor()
  local size   = ui.availableSpace()
  local x, y, w = origin.x, origin.y, size.x
  local bottom = origin.y + size.y
  local sim = ac.getSim()

  -- Disk checks on a timer, never per frame. Also re-fit the path strings on resize.
  local now = os.preciseClock()
  local period = math.clamp(cfg.refreshSeconds, 0.5, 10)
  if now - st.lastRefresh >= period then
    refresh(now, sim, w)
  elseif math.abs(w - st.fitW) > 1 then
    fitPaths(w)
  end

  local ppOn      = sim.isPostProcessingActive == true
  local activeLCS = sim.isLinearColorSpaceActive == true
  local activeOk
  if activeLCS then activeOk = st.lcsOk else activeOk = st.gammaOk end
  local showPaths = cfg.alwaysShowPaths

  -- Header: the filter name, big, with the .ini status dot and a small "Gamma"/"LCS" tag.
  ui.pushFont(ui.Font.Title)
  local name = st.nameShort
  local nm = ui.measureText(name)
  local headerH = nm.y + 2
  if y + headerH <= bottom then
    pDot:set(x + DOT_R + 1, y + nm.y * 0.5)
    ui.drawCircleFilled(pDot, DOT_R, (st.filter ~= '' and st.iniOk) and COL_OK or COL_BAD, 12)
    pText:set(x + LABEL_X, y)
    ui.drawText(name, pText, COL_VALUE)
  end
  ui.popFont()
  if y + headerH <= bottom then
    ui.pushFont(ui.Font.Small)
    local tag = st.iniOk and (activeLCS and 'LCS · ini ok' or 'Gamma · ini ok')
                         or (activeLCS and 'LCS · ini missing' or 'Gamma · ini missing')
    local tm = ui.measureText(tag)
    local tx = x + w - tm.x
    if tx > x + LABEL_X + nm.x + 6 then   -- only if it does not collide with the name
      pText:set(tx, y + nm.y - tm.y - 1)
      ui.drawText(tag, pText, st.iniOk and COL_LABEL or COL_BAD)
    end
    ui.popFont()
  end
  y = y + headerH + 3

  -- Post-processing switch: if this is off, no filter and no Pure script runs at all.
  y = drawRow('post-processing', ppOn and 'on' or 'off', ppOn and COL_OK or COL_BAD, ppOn and COL_OK or COL_BAD, x, y, w, bottom)

  -- Pure script per variant. The active variant is marked so the eye goes straight to the row that matters.
  y = drawRow(activeLCS and 'Pure script (Gamma)' or 'Pure script (Gamma) · active',
    st.gammaOk and 'found' or 'missing', st.gammaOk and COL_OK or COL_BAD, st.gammaOk and COL_OK or COL_BAD, x, y, w, bottom)
  if showPaths or not st.gammaOk then y = drawSubLine(st.gammaShort, x, y, bottom) end

  y = drawRow(activeLCS and 'Pure script (LCS) · active' or 'Pure script (LCS)',
    st.lcsOk and 'found' or 'missing', st.lcsOk and COL_OK or COL_BAD, st.lcsOk and COL_OK or COL_BAD, x, y, w, bottom)
  if showPaths or not st.lcsOk then y = drawSubLine(st.lcsShort, x, y, bottom) end

  -- Verdict: the actual symptom the user sees when the active variant has no script.
  y = y + 2
  if st.filter == '' then
    y = drawVerdict('no PP filter reported, nothing to check', COL_BAND_WARN, COL_WARN, x, y, w, bottom)
  elseif activeOk then
    y = drawVerdict('script for the active variant is present', COL_BAND_OK, COL_OK, x, y, w, bottom)
  else
    y = drawVerdict('Pure will use default_script.lua for this filter', COL_BAND_BAD, COL_BAD, x, y, w, bottom)
  end

  -- Exposure: camera exposure changes every frame (auto exposure), so these two are formatted per frame.
  local exposure = sim.cameraExposure or 0
  local mult = sim.exposureMultiplier or 1
  y = drawRow('exposure', string.format('%.3f', exposure), COL_NEUTRAL, COL_VALUE, x, y, w, bottom)

  -- Multiplier row with real buttons: place the ImGui cursor on the row, then draw - / + / reset.
  if y + rowH <= bottom then
    local rowY = y
    y = drawRow('multiplier', string.format('%.2f', mult), (math.abs(mult - 1) < 0.001) and COL_NEUTRAL or COL_WARN, COL_VALUE, x, y, w, bottom, true)
    local bw = btnSmall.x * 2 + btnWide.x + 6
    local bx = x + LABEL_X + 64 + 6                     -- right after the label, before the value
    if bx + bw < x + w - 44 then                        -- only when there is room between label and value
      pCur:set(bx, rowY + (rowH - btnSmall.y) * 0.5)
      ui.setCursor(pCur)
      if ui.button('-##expDown', btnSmall) then ac.setExposureMultiplier(math.clamp(mult - MULT_STEP, MULT_MIN, MULT_MAX)) end
      ui.sameLine(0, 3)
      if ui.button('+##expUp', btnSmall) then ac.setExposureMultiplier(math.clamp(mult + MULT_STEP, MULT_MIN, MULT_MAX)) end
      ui.sameLine(0, 3)
      if ui.button('reset##expReset', btnWide) then ac.setExposureMultiplier(1.0) end
    end
  else
    y = y + rowH
  end

  -- Time of day + sun angle, weather, and the render flags that change how a filter looks.
  y = drawRow('time', st.timeSunStr, st.sunNight and COL_INFO or COL_WARN, COL_VALUE, x, y, w, bottom)
  y = drawRow('rain', st.rainStr, st.raining and COL_INFO or COL_NEUTRAL, COL_VALUE, x, y, w, bottom)
  y = drawRow('temperature', st.tempStr, COL_NEUTRAL, COL_VALUE, x, y, w, bottom)
  y = drawRow('render', st.renderStr, activeLCS and COL_INFO or COL_NEUTRAL, COL_VALUE, x, y, w, bottom)
  y = drawRow('detail / window', st.detailStr, COL_NEUTRAL, COL_VALUE, x, y, w, bottom)

  -- Leave the ImGui cursor at the end of our content so the window's scroll/size bookkeeping is right.
  pCur:set(x, math.min(y, bottom))
  ui.setCursor(pCur)
end

-- ---------------------------------------------------------------- settings window
function script.windowSettings(dt)
  ui.text('Filter Doctor')
  ui.separator()
  cfg.refreshSeconds = math.clamp(ui.slider('##refreshSeconds', cfg.refreshSeconds, 0.5, 10, 'Re-check files every %.1f s'), 0.5, 10)
  if ui.checkbox('Always show expected script paths', cfg.alwaysShowPaths) then cfg.alwaysShowPaths = not cfg.alwaysShowPaths end
  if ui.button('Re-check now') then st.lastRefresh = -1e9 end
  ui.separator()
  ui.pushFont(ui.Font.Small)
  ui.textWrapped('Pure loads <ppfilters>/pure_scripts/<filter>.lua in Gamma mode and <ppfilters>/purelcs_scripts/<filter>.lua when linear colour space is on. If the file for the active variant is missing it silently uses default_script.lua.')
  if st.gammaLine ~= '' then
    ui.textWrapped(st.gammaLine)
    ui.textWrapped(st.lcsLine)
  end
  ui.popFont()
end
