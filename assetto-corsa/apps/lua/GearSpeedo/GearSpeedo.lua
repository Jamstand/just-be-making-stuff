--[[
  Gear Speedo - a small dashboard for Assetto Corsa (Custom Shaders Patch).

  Big gear indicator, road speed, and an 18-segment RPM bar with shift lights.

  The whole layout is derived from the current window size, so dragging the
  window edge scales everything together; the windows without a resize
  handle are scaled by the Size setting instead.

  Title bar and resize handle are window decorations that CSP fixes per
  window in manifest.ini and cannot change while running. So the manifest
  declares four windows - every combination of title bar on/off and resize
  handle on/off - all drawing the same HUD, and the two settings pick which
  one is open. CSP's own apps switch between their windows the same way
  (ac.setWindowOpen). The one CSP lists in its app list is `main`.
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
  opacity = 70,      -- background, percent. The windows have NO_BACKGROUND in
                     -- the manifest so this is the only fill behind the HUD.
  hideTitle = false, -- title bar: false = shows while the mouse is over the window, true = none
  hideGrip = false,  -- resize handle: true = none; the window is then sized by sizePct
  sizePct = 100,     -- window size without a resize handle, percent of 280x120
  lockPos = false,   -- pin the window where it is; -1 means "not captured yet"
  lockX = -1, lockY = -1, lockW = -1, lockH = -1,
}

local APP_NAME = 'Gear Speedo'   -- [ABOUT] NAME in manifest.ini

-- The four windows of manifest.ini. `title` / `grip` say which decorations
-- each one has; `name` is its NAME there (the title CSP lists it under).
local WINDOWS = {
  main      = { name = 'Gear Speedo',                            title = true,  grip = true  },
  bare      = { name = 'Gear Speedo (no title bar)',             title = false, grip = true  },
  fixed     = { name = 'Gear Speedo (fixed size)',               title = true,  grip = false },
  barefixed = { name = 'Gear Speedo (no title bar, fixed size)', title = false, grip = false },
}
local WINDOW_IDS = { 'main', 'bare', 'fixed', 'barefixed' }

local function wantedWindow()
  if settings.hideTitle then return settings.hideGrip and 'barefixed' or 'bare' end
  return settings.hideGrip and 'fixed' or 'main'
end

-- Size of the windows without a resize handle. They are AUTO_RESIZE, so
-- they take the size of their content, and this is what the content asks for.
local function fixedSize()
  return vec2(BASE_W * settings.sizePct / 100, BASE_H * settings.sizePct / 100)
end

-- Window accessors, one per window. CSP keys a Lua app's windows as
-- IMGUI_LUA_<[ABOUT] NAME>_<window ID>; ac.getAppWindows() lists them with
-- that key as `name` and the window's NAME as `title`, so the list is asked
-- first and the key is built by hand as the fallback. The accessor's
-- move/resize need CSP 0.2.3-preview62+; everything that uses one is
-- pcall-guarded and simply does nothing when it isn't there.
local accessors, accessorRetry = {}, {}
local function windowAccessor(id)
  if accessors[id] then return accessors[id] end
  if (accessorRetry[id] or 0) > 0 then accessorRetry[id] = accessorRetry[id] - 1; return nil end
  accessorRetry[id] = 120                   -- try again in ~2 s if not found
  if type(ac.accessAppWindow) ~= 'function' then return nil end
  local names = { 'IMGUI_LUA_' .. APP_NAME .. '_' .. id }
  if type(ac.getAppWindows) == 'function' then
    local ok, list = pcall(ac.getAppWindows)
    if ok and type(list) == 'table' then
      for _, w in ipairs(list) do
        if type(w) == 'table' and w.title == WINDOWS[id].name and type(w.name) == 'string' and w.name ~= names[1] then
          table.insert(names, 1, w.name)
        end
      end
    end
  end
  for _, name in ipairs(names) do
    local ok, a = pcall(ac.accessAppWindow, name)
    if ok and a ~= nil then
      local okv, valid = pcall(function() return a:valid() end)
      if okv and valid then accessors[id] = a; return a end
    end
  end
  return nil
end

-- Position lock. CSP has no manifest flag for this, so the app does it
-- itself: while locked it remembers where the window sits and, if anything
-- nudges it, moves it straight back via the window accessor.
local function enforceLock(id)
  if not settings.lockPos then return end
  local w = windowAccessor(id)
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
    if WINDOWS[id].grip and (math.abs(sz.x - settings.lockW) > 0.5 or math.abs(sz.y - settings.lockH) > 0.5) then
      w:resize(vec2(settings.lockW, settings.lockH))
    end
  end)
end

-- Switching windows -------------------------------------------------------

local function setOpen(id, open)
  if type(ac.setWindowOpen) ~= 'function' then return false end
  return pcall(ac.setWindowOpen, id, open)
end

local function isOpen(id)
  if type(ac.isWindowOpen) ~= 'function' then return false end
  local ok, v = pcall(ac.isWindowOpen, id)
  return ok and v == true
end

local function closeApp()
  for _, id in ipairs(WINDOW_IDS) do setOpen(id, false) end
end

local active, activeFrames = nil, 0   -- the window currently showing the HUD
local switching, switchWait = nil, 0  -- window we asked CSP to open, and how long we'll wait for it
local previous = nil                  -- window to close once the new one has drawn
local carry = nil                     -- { x, y, w, h, tries }: where the previous window sat

local function switchTo(id, fromId)
  if not setOpen(id, true) then
    -- Very old CSP without ac.setWindowOpen: stay where we are, and keep the
    -- settings honest about it.
    settings.hideTitle = not WINDOWS[fromId].title
    settings.hideGrip = not WINDOWS[fromId].grip
    return
  end
  if active == fromId then
    -- A setting changed while this window was showing: hand its spot, and
    -- its size, to the next one. (At load CSP opens `main` first whatever
    -- the settings say; then the wanted window keeps its own remembered
    -- spot and the saved size, and nothing is handed over.)
    local okp, p = pcall(ui.windowPos)
    if okp and p then
      local sz = WINDOWS[fromId].grip and ui.windowSize() or fixedSize()
      carry = { x = p.x, y = p.y, w = sz.x, h = sz.y, tries = 300 }
      if WINDOWS[fromId].grip and not WINDOWS[id].grip then
        -- From drag-to-resize to a fixed size: keep the scale the HUD is
        -- drawn at right now (the smaller of the two axes, as drawGauges does).
        local scale = math.min(sz.x / BASE_W, sz.y / BASE_H)
        settings.sizePct = math.floor(math.max(50, math.min(300, scale * 100)) + 0.5)
      end
    end
  end
  -- The lock re-captures on the new window, wherever it lands.
  settings.lockX, settings.lockY, settings.lockW, settings.lockH = -1, -1, -1, -1
  switching, switchWait, previous = id, 120, fromId
end

local function applyCarry(id)
  if not carry then return end
  carry.tries = carry.tries - 1
  if carry.tries <= 0 then carry = nil; return end
  local a = windowAccessor(id)
  if not a then return end
  pcall(function()
    a:move(vec2(carry.x, carry.y))
    if WINDOWS[id].grip then a:resize(vec2(carry.w, carry.h)) end
  end)
  carry = nil
end

local drawHud   -- defined below

local function drawWindow(id, dt)
  local want = wantedWindow()
  if id ~= want then
    if active and active ~= id and not isOpen(active) then
      active, activeFrames = nil, 0          -- CSP closed it behind our back
    end
    if active == want and isOpen(want) then
      -- The wanted window is already showing, so this one is surplus.
      if id == 'main' and switching == nil and activeFrames > 10 then
        -- CSP opened `main` on top of the variant that was showing: the
        -- player clicked the app in the app list, which to them means
        -- "close it". Close everything; with LAZY = FULL the app then unloads.
        closeApp()
      else
        setOpen(id, false)                   -- e.g. restored alongside it at session start
      end
      return
    end
    if switching ~= want then
      switchTo(want, id)
    else
      switchWait = switchWait - 1
      if switchWait <= 0 then
        -- The other window never came. Stay here and make the settings say so.
        switching, previous, carry = nil, nil, nil
        settings.hideTitle = not WINDOWS[id].title
        settings.hideGrip = not WINDOWS[id].grip
      end
    end
    -- Keep drawing this frame so the HUD doesn't blink while CSP swaps.
  else
    if active ~= id then
      active, activeFrames, switching = id, 0, nil
      if previous and previous ~= id then setOpen(previous, false) end
      previous = nil
    else
      activeFrames = activeFrames + 1
    end
    applyCarry(id)
  end
  drawHud(id, dt)
end

function script.windowMain(dt) drawWindow('main', dt) end
function script.windowBare(dt) drawWindow('bare', dt) end
function script.windowFixed(dt) drawWindow('fixed', dt) end
function script.windowBareFixed(dt) drawWindow('barefixed', dt) end

-- Controls for the windows without a title bar ----------------------------
-- They grow their own gear and close buttons, top right, while the mouse is
-- over them; right-clicking the widget opens the same settings.

local settingsOpen = false
local function openSettings()
  if settingsOpen or type(ui.popup) ~= 'function' then return end
  settingsOpen = true
  ui.popup(function() script.windowSettings(0) end, {
    padding = vec2(12, 12),
    onClose = function() settingsOpen = false end,
  })
end

local BTN = 22
local function hoverControls(size)
  if not ui.windowHovered() then return end
  -- A dark backing first, so the glyphs still read over a lit rev bar.
  ui.drawRectFilled(vec2(size.x - 2 * BTN - 8, 1), vec2(size.x - 2, BTN + 5), rgbm(0, 0, 0, 0.55), 4)
  ui.pushStyleColor(ui.StyleColor.Button, rgbm(0, 0, 0, 0))
  ui.pushStyleColor(ui.StyleColor.ButtonHovered, rgbm(1, 1, 1, 0.12))
  ui.pushStyleColor(ui.StyleColor.ButtonActive, rgbm(1, 1, 1, 0.22))
  ui.setCursor(vec2(size.x - 2 * BTN - 6, 3))
  if ui.iconButton(ui.Icons.Settings, vec2(BTN, BTN), 5) then openSettings() end
  if ui.itemHovered() then ui.setTooltip('Settings (or right-click the widget)') end
  ui.sameLine(0, 2)
  if ui.iconButton(ui.Icons.Cancel, vec2(BTN, BTN), 5) then closeApp() end
  if ui.itemHovered() then ui.setTooltip('Close Gear Speedo') end
  ui.popStyleColor(3)
  if ui.mouseClicked(ui.MouseButton.Right) then openSettings() end
end

-- The HUD -------------------------------------------------------------------

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

local function drawGauges(car, size, dt)
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

drawHud = function(id, dt)
  local win = WINDOWS[id]
  local size
  if win.grip then
    size = ui.windowSize()
  else
    size = fixedSize()
    ui.dummy(size)   -- an AUTO_RESIZE window takes the size of its content
  end

  -- Our own background first, at the chosen opacity, before anything else.
  ui.drawRectFilled(vec2(0, 0), size, rgbm(0, 0, 0, settings.opacity / 100), 4)

  enforceLock(id)

  -- ac.getCar can be nil for a frame or two while a session loads.
  local car = ac.getCar(0)
  if car then drawGauges(car, size, dt) end

  if not win.title then hoverControls(size) end
end

-- Settings ------------------------------------------------------------------
-- Behind the gear icon of the windows that have a title bar, and in the
-- popup the others open.

function script.windowSettings(dt)
  if ui.checkbox('Show speed', settings.showSpeed) then
    settings.showSpeed = not settings.showSpeed
  end

  if ui.checkbox('Show RPM bar', settings.showBar) then
    settings.showBar = not settings.showBar
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

  ui.separator()

  if ui.checkbox('Hide title bar', settings.hideTitle) then
    settings.hideTitle = not settings.hideTitle
  end
  if settings.hideTitle then
    ui.text('Point at the widget for its gear and close buttons, or right-click it.')
  end

  if ui.checkbox('Hide resize handle', settings.hideGrip) then
    settings.hideGrip = not settings.hideGrip
  end
  if settings.hideGrip and settings.lockPos then
    ui.text(('Size: %d%% (locked)'):format(settings.sizePct))
  elseif settings.hideGrip then
    ui.setNextItemWidth(180)
    local sz = ui.slider('##size', settings.sizePct, 50, 300, 'Size: %.0f%%')
    if ui.itemEdited() then
      settings.sizePct = sz
    end
  else
    ui.text('Drag the window edge to resize.')
  end

  if ui.checkbox('Lock position and size', settings.lockPos) then
    settings.lockPos = not settings.lockPos
    -- Capture afresh at the next frame so it holds wherever it is right now.
    settings.lockX, settings.lockY, settings.lockW, settings.lockH = -1, -1, -1, -1
  end
  if settings.lockPos then
    ui.text('Locked where it is. Untick to move or resize it.')
  end
end
