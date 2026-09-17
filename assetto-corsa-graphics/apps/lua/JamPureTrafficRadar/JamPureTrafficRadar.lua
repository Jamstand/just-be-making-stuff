-- JamPure Traffic Radar
-- A square, top-down radar centred on the player's car. Every other car in range is a dot;
-- the player's heading is always "up", so a dot above the centre is a car ahead of you.
-- Dot colour tells you how fast the gap is closing (red = closing fast, green = pulling away).
-- Nearest car ahead and nearest car behind get a small distance / closing-speed label.

script = script or {}

-- ---------------------------------------------------------------- settings (persisted by CSP)
local cfg = ac.storage{
  rangeM    = 300,   -- radar radius in metres (100..800)
  showNames = true,  -- online: label the nearest cars with driver names instead of ahead/behind
  dotScale  = 1.0,   -- multiplier on dot size (0.5..2)
  includeAI = true,  -- also show AI-controlled cars (offline traffic)
}

-- ---------------------------------------------------------------- constants
-- Closing-speed thresholds in km/h. Positive = the gap is shrinking.
local CLOSE_RED    = 30
local CLOSE_ORANGE = 10
local RECEDE_GREEN = -1   -- small deadband so a car holding station stays white, not flickering

-- Dot colours, indexed 1..4 = white / green / orange / red. Two sets: full for humans, dim for AI.
local DOT_COLS = {
  rgbm(1.00, 1.00, 1.00, 1.0),  -- 1 white: steady gap
  rgbm(0.55, 1.00, 0.55, 1.0),  -- 2 light green: receding
  rgbm(1.00, 0.60, 0.15, 1.0),  -- 3 orange: closing > 10 km/h
  rgbm(1.00, 0.20, 0.20, 1.0),  -- 4 red: closing > 30 km/h
}
local DOT_COLS_AI = {
  rgbm(1.00, 1.00, 1.00, 0.6),
  rgbm(0.55, 1.00, 0.55, 0.6),
  rgbm(1.00, 0.60, 0.15, 0.6),
  rgbm(1.00, 0.20, 0.20, 0.6),
}
local COL_RING   = rgbm(0.35, 0.35, 0.35, 0.8)   -- thin dark-grey range rings
local COL_CROSS  = rgbm(1.00, 1.00, 1.00, 0.10)  -- faint ahead/behind cross
local COL_PLAYER = rgbm.colors.white
local COL_LABEL  = rgbm(1.00, 1.00, 1.00, 0.95)
local COL_MUTED  = rgbm(1.00, 1.00, 1.00, 0.45)

-- ---------------------------------------------------------------- reusable scratch objects (no per-frame allocation)
local center = vec2()
local pDot   = vec2()
local pA     = vec2()
local pB     = vec2()
local pC     = vec2()
local pText  = vec2()

-- Cached "300 m" caption so string.format only runs when the range setting changes.
local rangeCaption, rangeCaptionFor = '', -1

local bgSet = false

-- ---------------------------------------------------------------- helpers

-- Picks a colour index from closing speed (km/h). See thresholds above.
local function colourIndex(closingKmh)
  if closingKmh > CLOSE_RED then return 4 end
  if closingKmh > CLOSE_ORANGE then return 3 end
  if closingKmh < RECEDE_GREEN then return 2 end
  return 1
end

-- Draws a label near a dot, flipping to the left of the dot if it would spill past the right
-- edge, then clamping into the window rectangle so nothing is drawn outside the panel.
local function drawDotLabel(text, dotX, dotY, dotR, ox, oy, w, h)
  local m = ui.measureText(text)
  local x = dotX + dotR + 3
  if x + m.x > ox + w - 2 then x = dotX - dotR - 3 - m.x end
  local y = dotY - m.y * 0.5
  x = math.clamp(x, ox + 2, math.max(ox + 2, ox + w - m.x - 2))
  y = math.clamp(y, oy + 2, math.max(oy + 2, oy + h - m.y - 2))
  pText:set(x, y)
  ui.drawText(text, pText, COL_LABEL)
end

-- Label text for the nearest car: "ahead 42m +12km/h", or the driver name when online + enabled.
local function labelFor(fallback, carIndex, dist, closingKmh, useNames)
  local name = fallback
  if useNames then
    local n = ac.getDriverName(carIndex)  -- may be nil for a disconnected slot
    if n and #n > 0 then
      if #n > 12 then n = n:sub(1, 12) end
      name = n
    end
  end
  return string.format('%s %dm %+dkm/h', name, dist, closingKmh)
end

-- ---------------------------------------------------------------- main window
function script.windowMain(dt)
  if not bgSet then
    ac.setWindowBackground('main', rgbm(0, 0, 0, 0.55), true)
    bgSet = true
  end

  local origin = ui.getCursor()
  local size   = ui.availableSpace()
  local ox, oy, w, h = origin.x, origin.y, size.x, size.y

  -- Radar geometry: biggest square that fits, 2 px margin, ranged to cfg.rangeM.
  local side   = math.min(w, h)
  local radius = math.max(side * 0.5 - 2, 4)
  local cx, cy = ox + w * 0.5, oy + h * 0.5
  center:set(cx, cy)
  local rangeM = math.clamp(cfg.rangeM, 100, 800)
  local scale  = radius / rangeM            -- pixels per metre
  local k      = math.clamp(side / 220, 0.5, 1.6)  -- everything scales gently with the window
  local dotK   = k * math.clamp(cfg.dotScale, 0.5, 2)

  -- Range rings at 1/3, 2/3 and full range, plus a faint ahead/behind cross.
  ui.drawCircle(center, radius / 3, COL_RING, 48, 1)
  ui.drawCircle(center, radius * 2 / 3, COL_RING, 48, 1)
  ui.drawCircle(center, radius, COL_RING, 64, 1)
  pA:set(cx, cy - radius); pB:set(cx, cy + radius)
  ui.drawLine(pA, pB, COL_CROSS, 1)
  pA:set(cx - radius, cy); pB:set(cx + radius, cy)
  ui.drawLine(pA, pB, COL_CROSS, 1)

  local sim = ac.getSim()
  local player = ac.getCar(0)
  if not player then
    ui.pushFont(ui.Font.Small)
    pText:set(ox + 4, oy + 4)
    ui.drawText('no car', pText, COL_MUTED)
    ui.popFont()
    return
  end

  local pp, pv = player.position, player.velocity
  local look, sideV = player.look, player.side
  local includeAI = cfg.includeAI
  local useNames = cfg.showNames and sim.isOnlineRace

  -- Nearest ahead / behind bookkeeping (distance, closing speed, dot screen pos, dot radius).
  local aheadIdx, aheadDist, aheadClose, aheadX, aheadY, aheadR = -1, 1e9, 0, 0, 0, 0
  local behindIdx, behindDist, behindClose, behindX, behindY, behindR = -1, 1e9, 0, 0, 0, 0
  local shown = 0

  -- Single pass over every other car. All vector maths is done on components so nothing is
  -- allocated per car: dx/dz below are exactly rel:dot(player.side) and rel:dot(player.look).
  for i = 1, sim.carsCount - 1 do
    local other = ac.getCar(i)
    if other and other.isActive and other.isConnected and not other.isHidingLabels
       and (includeAI or not other.isAIControlled) then
      local op = other.position
      local rx, ry, rz = op.x - pp.x, op.y - pp.y, op.z - pp.z
      local dx = rx * sideV.x + ry * sideV.y + rz * sideV.z   -- right (+) / left (-)
      local dz = rx * look.x  + ry * look.y  + rz * look.z    -- ahead (+) / behind (-)
      local dist = math.sqrt(dx * dx + dz * dz)              -- planar distance for the radar
      if dist <= rangeM then
        -- Closing speed = rate at which the 3D gap shrinks, from relative velocity projected on
        -- the line between the cars. Positive = approaching. Converted to km/h.
        local ov = other.velocity
        local vx, vy, vz = ov.x - pv.x, ov.y - pv.y, ov.z - pv.z
        local d3 = math.sqrt(rx * rx + ry * ry + rz * rz)
        local closingKmh = 0
        if d3 > 0.01 then
          closingKmh = -((vx * rx + vy * ry + vz * rz) / d3) * 3.6
        end

        local t = dist / rangeM                    -- 0 at centre, 1 at the edge
        local r = (5 - 2.5 * t) * dotK             -- 5 px near -> 2.5 px at the edge
        local sx, sy = cx + dx * scale, cy - dz * scale
        pDot:set(sx, sy)
        local ci = colourIndex(closingKmh)
        local col = other.isAIControlled and DOT_COLS_AI[ci] or DOT_COLS[ci]
        ui.drawCircleFilled(pDot, r, col, 16)
        shown = shown + 1

        if dz >= 0 then
          if dist < aheadDist then
            aheadIdx, aheadDist, aheadClose, aheadX, aheadY, aheadR = i, dist, closingKmh, sx, sy, r
          end
        elseif dist < behindDist then
          behindIdx, behindDist, behindClose, behindX, behindY, behindR = i, dist, closingKmh, sx, sy, r
        end
      end
    end
  end

  -- Player: small white triangle pointing up, drawn after the dots so it stays on top.
  local tri = 6 * k
  pA:set(cx, cy - tri)
  pB:set(cx - tri * 0.7, cy + tri * 0.7)
  pC:set(cx + tri * 0.7, cy + tri * 0.7)
  ui.drawTriangleFilled(pA, pB, pC, COL_PLAYER)

  -- Text layer: labels for nearest ahead/behind, or "no traffic"; range caption in the corner.
  ui.pushFont(ui.Font.Small)
  if shown == 0 then
    local msg = 'no traffic'
    local m = ui.measureText(msg)
    pText:set(cx - m.x * 0.5, math.min(cy + tri + 4, oy + h - m.y - 2))
    ui.drawText(msg, pText, COL_MUTED)
  else
    if aheadIdx >= 0 then
      drawDotLabel(labelFor('ahead', aheadIdx, aheadDist, aheadClose, useNames),
        aheadX, aheadY, aheadR, ox, oy, w, h)
    end
    if behindIdx >= 0 then
      drawDotLabel(labelFor('behind', behindIdx, behindDist, behindClose, useNames),
        behindX, behindY, behindR, ox, oy, w, h)
    end
  end

  if rangeCaptionFor ~= rangeM then
    rangeCaptionFor = rangeM
    rangeCaption = string.format('%d m', rangeM)
  end
  local cm = ui.measureText(rangeCaption)
  pText:set(ox + w - cm.x - 3, oy + h - cm.y - 2)
  ui.drawText(rangeCaption, pText, COL_MUTED)
  ui.popFont()
end

-- ---------------------------------------------------------------- settings window
function script.windowSettings(dt)
  ui.text('Traffic Radar')
  ui.separator()
  cfg.rangeM = math.clamp(ui.slider('##rangeM', cfg.rangeM, 100, 800, 'Range: %.0f m'), 100, 800)
  cfg.dotScale = math.clamp(ui.slider('##dotScale', cfg.dotScale, 0.5, 2, 'Dot size: %.2fx'), 0.5, 2)
  if ui.checkbox('Show driver names (online only)', cfg.showNames) then cfg.showNames = not cfg.showNames end
  if ui.checkbox('Include AI cars', cfg.includeAI) then cfg.includeAI = not cfg.includeAI end
  ui.offsetCursorY(4)
  ui.textWrapped('Dots: red = closing >30 km/h, orange = closing >10 km/h, green = pulling away, white = steady. AI cars are dimmer.')
end
