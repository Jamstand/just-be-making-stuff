-- Manifest probe: is manifest.ini wired to what GearSpeedo.lua defines, and
-- does it ask CSP for things the app relies on? Run: luajit verify/probe-manifest.lua
local HERE = (arg and arg[0] or 'x'):match('^(.*)[/\\]') or '.'
local DIR = HERE .. '/../apps/lua/GearSpeedo'
dofile(HERE .. '/cspstub.lua')
dofile(DIR .. '/GearSpeedo.lua')

local fails = 0
local function check(n, c, e)
  if c then print('  ok   ' .. n) else print('  FAIL ' .. n .. (e ~= nil and (' (' .. tostring(e) .. ')') or '')); fails = fails + 1 end
end
local function slurp(path) local f = assert(io.open(path, 'rb'), 'cannot open ' .. path); local s = f:read('*a'); f:close(); return s end

-- Tiny ini reader in the shape CSP uses: [sections], KEY = value, ';' comments.
local function readIni(text)
  local sections, cur, rawValues = {}, nil, {}
  for line in (text .. '\n'):gmatch('(.-)\r?\n') do
    local sec = line:match('^%s*%[(.-)%]%s*$')
    if sec then
      cur = { name = sec, kv = {} }; sections[#sections + 1] = cur
    elseif cur and not line:match('^%s*;') then
      local k, v = line:match('^%s*([%w_%.]+)%s*=%s*(.-)%s*$')
      if k then rawValues[#rawValues + 1] = { k = k, v = v }; cur.kv[k] = (v:gsub('%s*;.*$', '')) end
    end
  end
  return sections, rawValues
end

local text = slurp(DIR .. '/manifest.ini')
local sections, rawValues = readIni(text)
local function section(name) for _, s in ipairs(sections) do if s.name == name then return s.kv end end end
local about, core = section('ABOUT'), section('CORE')
local windows = {}
for _, s in ipairs(sections) do if s.name:match('^WINDOW_') then windows[#windows + 1] = s.kv end end

print('== sections ==')
check('[ABOUT] present', about ~= nil)
check('[CORE] present', core ~= nil)
check('exactly one [WINDOW_...]', #windows == 1, #windows)
local win = windows[1] or {}

print('== values CSP would cut short ==')
-- CSP treats ';' as the start of a comment anywhere on a line, which is fine
-- for a deliberate trailing comment but silently truncates prose fields.
local prose = { NAME = true, DESCRIPTION = true, AUTHOR = true, URL = true }
local cut = 0
for _, kv in ipairs(rawValues) do
  if kv.v:find(';', 1, true) then
    local kept = kv.v:gsub('%s*;.*$', '')
    if prose[kv.k] then cut = cut + 1; print(('    %s would be read as "%s"'):format(kv.k, kept))
    else print(('    (info) %s has a trailing comment; CSP reads "%s"'):format(kv.k, kept)) end
  end
end
check("no ';' inside NAME / DESCRIPTION / AUTHOR / URL (CSP would drop the rest of the line)", cut == 0, cut)
check('no tabs', not text:find('\t'), 'tab found')

print('== about ==')
check('NAME = Gear Speedo (README, checker and icon file names hang off it)', about and about.NAME == 'Gear Speedo', about and about.NAME)
local req = tonumber(about and about.REQUIRED_VERSION)
check('REQUIRED_VERSION is a build number', req ~= nil, about and about.REQUIRED_VERSION)

print('== core ==')
check('LAZY = FULL (load on open, unload when closed)', core and core.LAZY == 'FULL', core and core.LAZY)

print('== window ==')
check('ID = main', win.ID == 'main', win.ID)
check('NAME matches the app name', win.NAME ~= nil and about ~= nil and win.NAME == about.NAME, win.NAME)
check('ICON file exists next to the manifest', win.ICON and io.open(DIR .. '/' .. win.ICON, 'rb') ~= nil, win.ICON)
check('FUNCTION_MAIN names a function the script defines', win.FUNCTION_MAIN and type(script[win.FUNCTION_MAIN]) == 'function', win.FUNCTION_MAIN)
check('FUNCTION_SETTINGS names a function the script defines', win.FUNCTION_SETTINGS and type(script[win.FUNCTION_SETTINGS]) == 'function', win.FUNCTION_SETTINGS)

local flags, flagList = {}, {}
for f in (win.FLAGS or ''):gmatch('[^,%s]+') do flags[f] = true; flagList[#flagList + 1] = f end
print('  flags: ' .. table.concat(flagList, ', '))
-- Documented in the acc-lua-sdk wiki (Lua apps) plus the ones CSP's own apps use.
local known = {}
for _, f in ipairs{ 'AUTO_RESIZE', 'DARK_HEADER', 'FADING', 'FIXED_SIZE', 'FLOATING_TITLE_BAR', 'HANDLE_CTRL_TAB',
  'HIDDEN', 'HIDDEN_OFFLINE', 'HIDDEN_ONLINE', 'HIDDEN_RENDER_CUSTOM', 'HIDDEN_RENDER_SINGLE', 'HIDDEN_RENDER_TRIPLE',
  'HIDDEN_RENDER_VR', 'MAIN', 'NO_BACKGROUND', 'NO_COLLAPSE', 'NO_SCROLL_WITH_MOUSE', 'NO_SCROLLBAR', 'NO_TITLE_BAR',
  'SETTINGS', 'SETUP', 'SETUP_HIDDEN', 'SETUP_INLINE' } do known[f] = true end
local unknown = {}
for _, f in ipairs(flagList) do if not known[f] then unknown[#unknown + 1] = f end end
check('every flag is one CSP documents', #unknown == 0, table.concat(unknown, ', '))
check('SETTINGS flag present, since FUNCTION_SETTINGS is set (else no gear button)', flags.SETTINGS == true)
check('FLOATING_TITLE_BAR: title bar hidden until hovered', flags.FLOATING_TITLE_BAR == true)
check('not NO_TITLE_BAR (would hide the settings gear for good)', not flags.NO_TITLE_BAR)
check('NO_BACKGROUND, because the app paints its own at the chosen opacity', flags.NO_BACKGROUND == true)
check('NO_SCROLLBAR + NO_SCROLL_WITH_MOUSE (nothing to scroll in a HUD)', flags.NO_SCROLLBAR and flags.NO_SCROLL_WITH_MOUSE)
if flags.FLOATING_TITLE_BAR then
  -- FLOATING_TITLE_BAR arrived around build 2514 (CSP's own Radar gates it
  -- there). NO_BACKGROUND itself is much older; Radar only applies the two
  -- together because a transparent body under a fixed title bar looks odd.
  check('REQUIRED_VERSION >= 2514 for FLOATING_TITLE_BAR', req and req >= 2514, req)
end

local function pair(v) local a, b = (v or ''):match('^(%d+)%s*,%s*(%d+)$'); return tonumber(a), tonumber(b) end
local sw, sh = pair(win.SIZE); local nw, nh = pair(win.MIN_SIZE); local xw, xh = pair(win.MAX_SIZE)
check('SIZE / MIN_SIZE / MAX_SIZE parse as "w, h"', sw and nw and xw, tostring(win.SIZE) .. ' | ' .. tostring(win.MIN_SIZE) .. ' | ' .. tostring(win.MAX_SIZE))
if sw and nw and xw then
  check('MIN <= SIZE <= MAX', nw <= sw and sw <= xw and nh <= sh and sh <= xh)
  check('MIN and MAX keep the 280x120 aspect (so scaling stays uniform)', nw * sh == nh * sw and xw * sh == xh * sw)
  local src = slurp(DIR .. '/GearSpeedo.lua')
  local bw, bh = src:match('BASE_W,%s*BASE_H%s*=%s*(%d+),%s*(%d+)')
  check('SIZE equals the design size in GearSpeedo.lua (BASE_W, BASE_H)', tonumber(bw) == sw and tonumber(bh) == sh, tostring(bw) .. 'x' .. tostring(bh))
end

print('== the app paints the background NO_BACKGROUND removes ==')
setWindow(sw or 280, sh or 120); CAR.gear, CAR.rpm, CAR.rpmLimiter, CAR.speedKmh = 3, 4000, 7500, 120
local mainFn = script[win.FUNCTION_MAIN or 'windowMain']
reset(); if type(mainFn) == 'function' then mainFn(1 / 60) end
local bg = RECT[1]
check('first draw call is a full-window fill', type(mainFn) == 'function' and bg and bg.p1.x == 0 and bg.p1.y == 0 and bg.p2.x == (sw or 280) and bg.p2.y == (sh or 120))

print('== settings window describes the title bar the manifest asks for ==')
check('script read its own manifest through ac.INIConfig', INI_LOADS[1] ~= nil and INI_LOADS[1]:match('manifest%.ini$') ~= nil, INI_LOADS[1])
local said = {}
local realText = ui.text
ui.text = function(t) said[#said + 1] = t end
script[win.FUNCTION_SETTINGS or 'windowSettings'](1 / 60)
ui.text = realText
local tbLine
for _, t in ipairs(said) do if t:match('^Title bar:') then tbLine = t end end
check('settings window has a "Title bar:" line', tbLine ~= nil)
if tbLine then
  local expect = flags.NO_TITLE_BAR and 'none' or flags.FLOATING_TITLE_BAR and 'hidden until the mouse' or 'always shown'
  check('it says "' .. expect .. '", matching FLAGS', tbLine:find(expect, 1, true) ~= nil, tbLine)
end

print('== lock feature can find the window under the manifest names ==')
local src = slurp(DIR .. '/GearSpeedo.lua')
local candidates = src:match('for _, name in ipairs%(%{(.-)%}%)') or ''
check("candidate list includes the window NAME '" .. tostring(win.NAME) .. "'", candidates:find("'" .. tostring(win.NAME) .. "'", 1, true) ~= nil)
check('candidate list includes the folder name GearSpeedo', candidates:find("'GearSpeedo'", 1, true) ~= nil)

print(('\n%d failure(s)'):format(fails)); os.exit(fails > 0 and 1 or 0)
