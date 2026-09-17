-- JamPure Frame Time
-- A small performance panel: the last 240 real frame times live in a ring buffer fed from
-- ac.getUI().dt (which keeps ticking while the sim is paused). From that buffer we show a big
-- fps number, the average / 1% low / worst frame time, and a bar graph where every bar is one
-- frame, coloured against a selectable target fps (60 / 120 / 144). The footer lists the things
-- that usually explain a bad graph: car count, VRAM, MSAA, FSR, LCS, detail level, resolution.

script = script or {}

-- ---------------------------------------------------------------- settings (persisted by CSP)
local cfg = ac.storage{
  targetFps     = 120,   -- 60 / 120 / 144; the dashed line in the graph sits at 1000 / targetFps ms
  graphHeight   = 48,    -- graph height in px (20..200); clamped to what the window can fit
  pauseInReplay = false, -- freeze the buffer (and therefore the graph) while a replay is playing
}

-- ---------------------------------------------------------------- constants
local N            = 240   -- ring buffer length: one bar per sample in the graph
local RECENT       = 30    -- fps readout = 1000 / mean of the last RECENT samples
local SORT_PERIOD  = 0.25  -- seconds between percentile sorts (4 per second, never per frame)
local TARGET_AT    = 0.6   -- the target frame time sits at 60% of the graph height
local DASH_LEN     = 6     -- dashed target line: dash / gap in px
local DASH_GAP     = 4

-- Bar colours: green under the target frame time, yellow under 2x target, red above.
local COL_GREEN    = rgbm(0.35, 0.85, 0.40, 0.95)
local COL_YELLOW   = rgbm(0.95, 0.80, 0.20, 0.95)
local COL_RED      = rgbm(0.95, 0.30, 0.25, 0.95)
local COL_LINE     = rgbm(1.00, 1.00, 1.00, 0.55)  -- dashed target line
local COL_GRAPH_BG = rgbm(1.00, 1.00, 1.00, 0.05)  -- faint box behind the bars
local COL_MUTED    = rgbm(1.00, 1.00, 1.00, 0.55)  -- small labels
local COL_FROZEN   = rgbm(1.00, 0.80, 0.20, 0.90)  -- "frozen" tag while paused in replay

-- ---------------------------------------------------------------- ring buffer state
local buf    = {}   -- buf[1..N] frame times in ms; slots not yet filled hold 0
local sorted = {}   -- scratch copy for the percentile sort, same size, reused every time
for i = 1, N do buf[i] = 0; sorted[i] = 0 end
local head  = 0     -- slot of the newest sample (1..N), 0 until the first sample lands
local count = 0     -- valid samples so far (grows to N and stays there)

-- Live numbers, recomputed every frame from the buffer (cheap loops, no allocation).
local fps, avgMs, worstMs = 0, 0, 0
-- Numbers that only refresh at SORT_PERIOD: the 1% low needs a sort, and the strings are
-- rebuilt at the same cadence so the panel is readable and we don't string.format every frame.
local lowFps = 0
local sortTimer = SORT_PERIOD   -- start "due" so the first refresh happens on frame one
local fpsStr, statsStr, footerA, footerB = '--', 'avg - ms · 1% low - · worst - ms', '', ''

-- Reusable scratch vectors so the draw loops don't allocate.
local p1 = vec2()
local p2 = vec2()

local bgSet = false

-- ---------------------------------------------------------------- helpers

-- The stored target could be anything after a manual edit of the storage file; only 60/120/144 are valid.
local function targetFps()
  local t = cfg.targetFps
  if t == 60 or t == 120 or t == 144 then return t end
  return 120
end

-- Pushes one frame time (ms) into the ring buffer.
local function pushSample(ms)
  head = head % N + 1
  buf[head] = ms
  if count < N then count = count + 1 end
end

-- Recomputes fps / average / worst from the buffer. Two short loops, called every frame.
local function updateStats()
  if count == 0 then fps, avgMs, worstMs = 0, 0, 0 return end
  local sum, worst = 0, 0
  for i = 1, count do
    local v = buf[i]
    sum = sum + v
    if v > worst then worst = v end
  end
  avgMs, worstMs = sum / count, worst
  -- Mean of the newest RECENT samples, walking backwards from head.
  local n = count < RECENT and count or RECENT
  local recent, i = 0, head
  for _ = 1, n do
    recent = recent + buf[i]
    i = i - 1
    if i < 1 then i = N end
  end
  fps = recent > 0 and 1000 * n / recent or 0
end

-- 1% low: sort a copy of the buffer and take the 99th-percentile frame time. Unused slots are 0,
-- so after sorting the real samples occupy sorted[N - count + 1 .. N] and the percentile index
-- is offset accordingly. Only called from the 4 Hz refresh, never per frame.
local function updateLow()
  if count == 0 then lowFps = 0 return end
  for i = 1, N do sorted[i] = buf[i] end
  table.sort(sorted)
  local rank = math.ceil(count * 0.99)
  if rank < 1 then rank = 1 elseif rank > count then rank = count end
  local p99 = sorted[N - count + rank]
  lowFps = p99 > 0 and 1000 / p99 or 0
end

-- Rebuilds every string the panel shows. Runs at SORT_PERIOD cadence.
local function refreshText(sim)
  if count == 0 then
    fpsStr = '--'                    -- nothing sampled yet (e.g. opened during a frozen replay)
    statsStr = 'avg - ms · 1% low - · worst - ms'
  else
    fpsStr = string.format('%d', math.floor(fps + 0.5))
    statsStr = string.format('avg %.1f ms · 1%% low %d · worst %.0f ms', avgMs, math.floor(lowFps + 0.5), worstMs)
  end

  local vramStr = 'VRAM n/a'
  local vr = ac.getVRAMConsumption()
  if vr and vr.usage and vr.budget then
    vramStr = string.format('VRAM %d/%d MB', math.floor(vr.usage + 0.5), math.floor(vr.budget + 0.5))
  end
  local cars = sim and sim.carsCount or 0
  footerA = string.format('%d car%s · %s', cars, cars == 1 and '' or 's', vramStr)
  footerB = string.format('MSAA x%d · FSR %s · LCS %s · detail %d · %dx%d',
    sim and sim.msaaSamples or 0,
    sim and sim.isFSRActive and 'on' or 'off',
    sim and sim.isLinearColorSpaceActive and 'on' or 'off',
    sim and sim.worldDetailLevel or 0,
    sim and sim.windowWidth or 0, sim and sim.windowHeight or 0)
end

-- Draws the bar graph into the box (ox, oy, w, h). Newest sample is the right-most bar.
local function drawGraph(ox, oy, w, h, target)
  p1:set(ox, oy); p2:set(ox + w, oy + h)
  ui.drawRectFilled(p1, p2, COL_GRAPH_BG)

  local targetMs = 1000 / target
  local pxPerMs = h * TARGET_AT / targetMs     -- scale so the target frame time lands at 60% height
  local barW = w / N
  local bw = barW > 2 and barW - 1 or barW     -- leave a 1 px gap only when bars are wide enough
  local bottom = oy + h

  -- Walk the buffer oldest -> newest so the graph scrolls left as new frames arrive.
  local i = head - count + 1
  if i < 1 then i = i + N end
  local x = ox + w - count * barW
  for _ = 1, count do
    local ms = buf[i]
    local bh = ms * pxPerMs
    if bh > h then bh = h end                  -- never draw above the box
    if bh < 1 then bh = 1 end                  -- always show at least a sliver
    local col = COL_GREEN
    if ms > targetMs * 2 then col = COL_RED elseif ms > targetMs then col = COL_YELLOW end
    p1:set(x, bottom - bh); p2:set(x + bw, bottom)
    ui.drawRectFilled(p1, p2, col)
    x = x + barW
    i = i + 1
    if i > N then i = 1 end
  end

  -- Thin dashed target line at 60% height (y grows downwards, so 40% from the top).
  local ly = oy + h * (1 - TARGET_AT)
  local right = ox + w
  local dx = ox
  while dx < right do
    local dxEnd = dx + DASH_LEN
    if dxEnd > right then dxEnd = right end
    p1:set(dx, ly); p2:set(dxEnd, ly)
    ui.drawLine(p1, p2, COL_LINE, 1)
    dx = dx + DASH_LEN + DASH_GAP
  end
end

-- ---------------------------------------------------------------- main window
function script.windowMain(dt)
  if not bgSet then
    ac.setWindowBackground('main', rgbm(0, 0, 0, 0.55), true)
    bgSet = true
  end

  local sim = ac.getSim()
  local uiState = ac.getUI()
  local realDt = uiState and uiState.dt or 0
  local frozen = cfg.pauseInReplay and sim and sim.isReplayActive or false

  -- Sample the real frame time (ticks while paused). Skip garbage: 0 on the very first frame,
  -- huge values after a hitch/alt-tab, and everything while the graph is frozen for a replay.
  if not frozen and realDt > 0 and realDt <= 1 then
    pushSample(realDt * 1000)
  end
  updateStats()

  -- 4 Hz refresh of the sort-based 1% low and of every display string.
  sortTimer = sortTimer + (realDt > 0 and realDt <= 1 and realDt or 0)
  if sortTimer >= SORT_PERIOD then
    sortTimer = 0
    updateLow()
    refreshText(sim)
  end

  local target = targetFps()

  -- Big fps number with a small "fps" label sitting next to its baseline.
  local hx, hy = ui.getCursorX(), ui.getCursorY()
  ui.pushFont(ui.Font.Huge)
  local big = ui.measureText(fpsStr)
  ui.text(fpsStr)
  ui.popFont()
  local labelY = hy + big.y - 18
  if labelY < hy then labelY = hy end
  p1:set(hx + big.x + 6, labelY)
  ui.drawText('fps', p1, COL_MUTED)

  -- avg / 1% low / worst line.
  ui.pushFont(ui.Font.Small)
  ui.textColored(statsStr, COL_MUTED)
  ui.popFont()

  -- Graph: takes cfg.graphHeight, but never more than what is left after the two footer lines,
  -- and is skipped entirely when the window is too small to fit it.
  local gOrigin = ui.getCursor()
  local space = ui.availableSpace()
  local footerH = 30
  local gh = cfg.graphHeight
  if gh > space.y - footerH then gh = space.y - footerH end
  if gh >= 6 and space.x >= 8 then
    drawGraph(gOrigin.x, gOrigin.y, space.x, gh, target)
    if frozen then
      p1:set(gOrigin.x + 4, gOrigin.y + 2)
      ui.drawText('frozen (replay)', p1, COL_FROZEN)
    end
    ui.offsetCursorY(gh + 3)
  end

  -- Footer: two small muted lines with the render setup.
  ui.pushFont(ui.Font.Small)
  ui.textColored(footerA, COL_MUTED)
  ui.textColored(footerB, COL_MUTED)
  ui.popFont()
end

-- ---------------------------------------------------------------- settings window
function script.windowSettings(dt)
  ui.text('Frame Time')
  ui.separator()

  -- Target fps: three checkboxes acting as a radio group (exactly one is ever ticked).
  ui.text('Target fps (dashed line)')
  local t = targetFps()
  if ui.checkbox('60', t == 60) then cfg.targetFps = 60 end
  ui.sameLine()
  if ui.checkbox('120', t == 120) then cfg.targetFps = 120 end
  ui.sameLine()
  if ui.checkbox('144', t == 144) then cfg.targetFps = 144 end

  local gh = ui.slider('##graphHeight', cfg.graphHeight, 20, 200, 'Graph height: %.0f px')
  cfg.graphHeight = math.floor(math.clamp(gh, 20, 200) + 0.5)

  if ui.checkbox('Pause graph in replay', cfg.pauseInReplay) then cfg.pauseInReplay = not cfg.pauseInReplay end

  ui.separator()
  ui.pushFont(ui.Font.Small)
  ui.textWrapped('Bars: green under the target frame time, yellow under 2x, red above. Frame times come from the real UI clock, so the graph keeps moving while the sim is paused.')
  ui.popFont()
end
