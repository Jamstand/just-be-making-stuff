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
check('four [WINDOW_...] sections: title bar on/off x resize handle on/off', #windows == 4, #windows)
local byId = {}
for _, w in ipairs(windows) do if w.ID then byId[w.ID] = w end end
local EXPECT = {
  main      = { title = true,  grip = true,  fn = 'windowMain' },
  bare      = { title = false, grip = true,  fn = 'windowBare' },
  fixed     = { title = true,  grip = false, fn = 'windowFixed' },
  barefixed = { title = false, grip = false, fn = 'windowBareFixed' },
}
local ORDER = { 'main', 'bare', 'fixed', 'barefixed' }
for _, id in ipairs(ORDER) do check('window "' .. id .. '" declared', byId[id] ~= nil) end
check('main is the first window (the one CSP lists)', windows[1] and windows[1].ID == 'main', windows[1] and windows[1].ID)

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
check('LAZY = FULL (load on open, unload when every window is closed)', core and core.LAZY == 'FULL', core and core.LAZY)

-- Documented in the acc-lua-sdk wiki (Lua apps) plus the ones CSP's own apps use.
local known = {}
for _, f in ipairs{ 'AUTO_RESIZE', 'DARK_HEADER', 'FADING', 'FIXED_SIZE', 'FLOATING_TITLE_BAR', 'HANDLE_CTRL_TAB',
  'HIDDEN', 'HIDDEN_OFFLINE', 'HIDDEN_ONLINE', 'HIDDEN_RENDER_CUSTOM', 'HIDDEN_RENDER_SINGLE', 'HIDDEN_RENDER_TRIPLE',
  'HIDDEN_RENDER_VR', 'MAIN', 'NO_BACKGROUND', 'NO_COLLAPSE', 'NO_SCROLL_WITH_MOUSE', 'NO_SCROLLBAR', 'NO_TITLE_BAR',
  'SETTINGS', 'SETUP', 'SETUP_HIDDEN', 'SETUP_INLINE' } do known[f] = true end
local function pair(v) local a, b = (v or ''):match('^(%d+)%s*,%s*(%d+)$'); return tonumber(a), tonumber(b) end
local src = slurp(DIR .. '/GearSpeedo.lua')
local names, anyFloating = {}, false

for _, id in ipairs(ORDER) do
  local win, exp = byId[id], EXPECT[id]
  if win then
    print('== window ' .. id .. ' ==')
    local flags, flagList = {}, {}
    for f in (win.FLAGS or ''):gmatch('[^,%s]+') do flags[f] = true; flagList[#flagList + 1] = f end
    print('  flags: ' .. table.concat(flagList, ', '))
    local unknown = {}
    for _, f in ipairs(flagList) do if not known[f] then unknown[#unknown + 1] = f end end
    check('every flag is one CSP documents or its own apps use', #unknown == 0, table.concat(unknown, ', '))
    check('NAME set and unique', win.NAME ~= nil and not names[win.NAME], win.NAME); names[win.NAME or ''] = true
    check('NAME appears in the script\'s window table (it matches CSP\'s window list by this title)', win.NAME and src:find("'" .. win.NAME .. "'", 1, true) ~= nil, win.NAME)
    check('ICON file exists next to the manifest', win.ICON and io.open(DIR .. '/' .. win.ICON, 'rb') ~= nil, win.ICON)
    check('FUNCTION_MAIN = ' .. exp.fn .. ', and the script defines it', win.FUNCTION_MAIN == exp.fn and type(script[exp.fn]) == 'function', win.FUNCTION_MAIN)
    check('NO_BACKGROUND (the app paints its own at the chosen opacity)', flags.NO_BACKGROUND == true)
    check('NO_SCROLLBAR + NO_SCROLL_WITH_MOUSE (nothing to scroll in a HUD)', flags.NO_SCROLLBAR and flags.NO_SCROLL_WITH_MOUSE)
    if id == 'main' then
      check('MAIN flag: this is the app-list window', flags.MAIN == true)
      check('not HIDDEN: opens with the app', not flags.HIDDEN)
    else
      check('HIDDEN: only the script opens it', flags.HIDDEN == true)
      check('no MAIN flag', not flags.MAIN)
    end
    if exp.title then
      check('FLOATING_TITLE_BAR: title bar hidden until hovered', flags.FLOATING_TITLE_BAR == true); anyFloating = anyFloating or flags.FLOATING_TITLE_BAR
      check('not NO_TITLE_BAR', not flags.NO_TITLE_BAR)
      check('SETTINGS flag + FUNCTION_SETTINGS the script defines (the gear icon)', flags.SETTINGS == true and win.FUNCTION_SETTINGS and type(script[win.FUNCTION_SETTINGS]) == 'function', win.FUNCTION_SETTINGS)
    else
      check('NO_TITLE_BAR', flags.NO_TITLE_BAR == true)
      check('no FLOATING_TITLE_BAR (would be pointless without a bar)', not flags.FLOATING_TITLE_BAR)
      check('no SETTINGS flag (no bar to put the gear on; the window draws its own)', not flags.SETTINGS and win.FUNCTION_SETTINGS == nil)
    end
    if exp.grip then
      check('resizable: no AUTO_RESIZE / FIXED_SIZE', not flags.AUTO_RESIZE and not flags.FIXED_SIZE)
    else
      check('AUTO_RESIZE: sized by its content, so no resize handle', flags.AUTO_RESIZE == true)
      local pw, ph = pair(win.PADDING)
      check('PADDING = 0, 0 so the content size is the window size', pw == 0 and ph == 0, win.PADDING)
    end
    local sw, sh = pair(win.SIZE); local nw, nh = pair(win.MIN_SIZE); local xw, xh = pair(win.MAX_SIZE)
    check('SIZE / MIN_SIZE / MAX_SIZE parse as "w, h"', sw and nw and xw, tostring(win.SIZE) .. ' | ' .. tostring(win.MIN_SIZE) .. ' | ' .. tostring(win.MAX_SIZE))
    if sw and nw and xw then
      check('MIN <= SIZE <= MAX', nw <= sw and sw <= xw and nh <= sh and sh <= xh)
      check('MIN and MAX keep the 280x120 aspect (so scaling stays uniform)', nw * sh == nh * sw and xw * sh == xh * sw)
      local bw, bh = src:match('BASE_W,%s*BASE_H%s*=%s*(%d+),%s*(%d+)')
      check('SIZE equals the design size in GearSpeedo.lua (BASE_W, BASE_H)', tonumber(bw) == sw and tonumber(bh) == sh, tostring(bw) .. 'x' .. tostring(bh))
      if not exp.grip then
        local lo, hi = src:match("ui%.slider%('##size',%s*settings%.sizePct,%s*(%d+),%s*(%d+)")
        check('Size slider range (' .. tostring(lo) .. '-' .. tostring(hi) .. '%) stays inside MIN/MAX', lo and hi and sw * tonumber(lo) / 100 >= nw and sw * tonumber(hi) / 100 <= xw)
      end
    end
  end
end

if anyFloating then
  -- FLOATING_TITLE_BAR arrived around build 2514 (CSP's own Radar gates it there).
  check('REQUIRED_VERSION >= 2514 for FLOATING_TITLE_BAR', req and req >= 2514, req)
end

print('== script and manifest agree on the window ids ==')
for _, id in ipairs(ORDER) do
  check("script's window table has '" .. id .. "'", src:find('^%s*' .. id .. '%s*=%s*{') ~= nil or src:find('\n%s*' .. id .. '%s*=%s*{') ~= nil)
end

print('== the app paints the background NO_BACKGROUND removes ==')
setWindow(280, 120); CAR.gear, CAR.rpm, CAR.rpmLimiter, CAR.speedKmh = 3, 4000, 7500, 120
local mainFn = script[(byId.main and byId.main.FUNCTION_MAIN) or 'windowMain']
reset(); if type(mainFn) == 'function' then mainFn(1 / 60) end
local bg = RECT[1]
check('first draw call is a full-window fill', type(mainFn) == 'function' and bg and bg.p1.x == 0 and bg.p1.y == 0 and bg.p2.x == 280 and bg.p2.y == 120)

print('== settings window offers the switches the windows exist for ==')
local labels = {}
local realCheckbox = ui.checkbox
local setFn = script[(byId.main and byId.main.FUNCTION_SETTINGS) or 'windowSettings']
ui.checkbox = function(l) labels[#labels + 1] = l; return false end
if type(setFn) == 'function' then setFn(1 / 60) end
ui.checkbox = realCheckbox
local have = {}
for _, l in ipairs(labels) do have[l] = true end
check("'Hide title bar' checkbox", have['Hide title bar'])
check("'Hide resize handle' checkbox", have['Hide resize handle'])
check("'Lock position and size' checkbox", have['Lock position and size'])

print('== accessor key: IMGUI_LUA_<[ABOUT] NAME>_<window ID> ==')
local appName = src:match("APP_NAME%s*=%s*'(.-)'")
check("script's APP_NAME equals [ABOUT] NAME", appName ~= nil and about ~= nil and appName == about.NAME, tostring(appName))
check('key built as IMGUI_LUA_ .. APP_NAME .. _ .. id', src:find("'IMGUI_LUA_' .. APP_NAME .. '_' .. id", 1, true) ~= nil)
check('and ac.getAppWindows() consulted first', src:find('ac.getAppWindows', 1, true) ~= nil)

print(('\n%d failure(s)'):format(fails)); os.exit(fails > 0 and 1 or 0)
