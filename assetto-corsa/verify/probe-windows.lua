-- Window switching probes: title bar / resize handle settings pick one of the
-- four manifest windows; the title-bar-less ones grow their own controls.
-- Run: luajit verify/probe-windows.lua
local HERE = (arg and arg[0] or 'x'):match('^(.*)[/\\]') or '.'
local APP = HERE .. '/../apps/lua/GearSpeedo/GearSpeedo.lua'
dofile(HERE .. '/cspstub.lua')
local fails = 0
local function check(n, c, e) if c then print('  ok   ' .. n) else print('  FAIL ' .. n .. (e ~= nil and (' (' .. tostring(e) .. ')') or '')); fails = fails + 1 end end
local FN = { main = 'windowMain', bare = 'windowBare', fixed = 'windowFixed', barefixed = 'windowBareFixed' }
local function frame(id, n) for _ = 1, (n or 1) do reset(); script[FN[id]](1 / 60) end end
local function openSet() local t = {} for id, v in pairs(OPEN) do if v then t[#t + 1] = id end end table.sort(t) return table.concat(t, ',') end
local function tick(label, v) ui.checkbox = function(l) return l == label end; script.windowSettings(1 / 60); ui.checkbox = function() return false end end
local function fresh() dofile(APP); OPEN = { main = true }; OPEN_LOG = {}; WIN_ACCESS.moves, WIN_ACCESS.resizes = {}, {}; ACCESS_CALLS = {}; POPUPS = {}; CLICK = {}; HOVER = false; RCLICK = false end
CAR.gear, CAR.rpm, CAR.rpmLimiter, CAR.speedKmh = 3, 4000, 7500, 120

print('== defaults: main window, nothing switches ==')
fresh(); setWindow(280, 120)
frame('main', 5)
check('only main open', openSet() == 'main', openSet())
check('no setWindowOpen calls at all', #OPEN_LOG == 0, #OPEN_LOG)
check('HUD drawn (background + 18 segments + divider)', #RECT == 20, #RECT)
check('no hover controls on a window with a title bar even when hovered', (function() HOVER = true; frame('main'); HOVER = false; return #ICONBTN == 0 end)())
check('no ui.dummy on a resizable window', #DUMMY == 0)

print('== settings: Hide title bar -> bare window takes over where main sat ==')
WINPOS = { x = 400, y = 300 }; setWindow(420, 180)
tick('Hide title bar')
check('setting stored', STORAGE.hideTitle == true)
frame('main')                                    -- main notices and asks CSP for `bare`
check('bare asked to open, main still open (not closed before bare has drawn)', OPEN.bare == true and OPEN.main == true, openSet())
check('main still drew its HUD that frame', #RECT == 20, #RECT)
WIN_ACCESS.name = 'IMGUI_LUA_Gear Speedo_bare'; WIN_ACCESS.title = 'Gear Speedo (no title bar)'
WIN_ACCESS.pos = { x = 10, y = 10 }; WIN_ACCESS.size = { x = 280, y = 120 }
frame('bare')                                    -- bare's first frame
check('main closed once bare has drawn', OPEN.main == false and OPEN.bare == true, openSet())
check('bare moved to where main was (400,300)', WIN_ACCESS.pos.x == 400 and WIN_ACCESS.pos.y == 300, WIN_ACCESS.pos.x .. ',' .. WIN_ACCESS.pos.y)
check('and resized to main\'s 420x180', WIN_ACCESS.size.x == 420 and WIN_ACCESS.size.y == 180, WIN_ACCESS.size.x .. 'x' .. WIN_ACCESS.size.y)
check('accessor looked up under CSP\'s key for the bare window', ACCESS_CALLS[1] == 'IMGUI_LUA_Gear Speedo_bare', ACCESS_CALLS[1])
frame('bare', 5)
check('exactly one move and one resize (no re-applying)', #WIN_ACCESS.moves == 1 and #WIN_ACCESS.resizes == 1, #WIN_ACCESS.moves .. '/' .. #WIN_ACCESS.resizes)
check('HUD still complete in bare', #RECT == 20 and #TEXT == 4, #RECT .. '/' .. #TEXT)

print('== bare window: hover controls ==')
HOVER = false; frame('bare')
check('nothing drawn when not hovered', #ICONBTN == 0)
HOVER = true; frame('bare')
check('gear + close buttons appear when hovered', #ICONBTN == 2 and ICONBTN[1].icon == ui.Icons.Settings and ICONBTN[2].icon == ui.Icons.Cancel, #ICONBTN)
check('placed at the top right of the window', ICONBTN[1].at and ICONBTN[1].at.y == 3 and ICONBTN[1].at.x > 420 - 60 and ICONBTN[1].at.x < 420, ICONBTN[1].at and ICONBTN[1].at.x)
check('style pushes balanced', STYLE_DEPTH == 0, STYLE_DEPTH)
check('fonts balanced', #FONTS == 0)
CLICK[ui.Icons.Settings] = true; frame('bare'); CLICK = {}
check('gear opens a settings popup', #POPUPS == 1, #POPUPS)
frame('bare', 3); RCLICK = true; frame('bare'); RCLICK = false
check('right-click while a popup is open does not open a second one', #POPUPS == 1, #POPUPS)
local labels = {}
ui.checkbox = function(l) labels[#labels + 1] = l; return false end
POPUPS[1].fn(); ui.checkbox = function() return false end
check('popup shows the same settings (Hide title bar, Hide resize handle, Lock...)', (function()
  local want = { ['Hide title bar'] = true, ['Hide resize handle'] = true, ['Lock position and size'] = true, ['Show speed'] = true }
  for _, l in ipairs(labels) do want[l] = nil end
  return next(want) == nil end)(), table.concat(labels, '|'))
POPUPS[1].params.onClose(); POPUPS = {}
RCLICK = true; frame('bare'); RCLICK = false
check('right-click opens the settings popup again once closed', #POPUPS == 1, #POPUPS)
HOVER = false

print('== app-list click while bare is showing = close ==')
frame('bare', 15)
OPEN.main = true; OPEN_LOG = {}
frame('main')
check('everything closed (LAZY = FULL unloads the app)', openSet() == '', openSet())

print('== close button ==')
fresh(); STORAGE.hideTitle = true; OPEN = { bare = true }
HOVER = true; frame('bare', 2); CLICK[ui.Icons.Cancel] = true; frame('bare'); CLICK = {}; HOVER = false
check('X closes every window', openSet() == '', openSet())

print('== reload with both hidden: main -> barefixed, sized by the setting ==')
fresh(); STORAGE.hideTitle = true; STORAGE.hideGrip = true; STORAGE.sizePct = 150
WINPOS = { x = 50, y = 60 }; setWindow(280, 120)
frame('main')
check('barefixed asked to open', OPEN.barefixed == true, openSet())
WIN_ACCESS.name = 'IMGUI_LUA_Gear Speedo_barefixed'; WIN_ACCESS.title = 'Gear Speedo (no title bar, fixed size)'; WIN_ACCESS.pos = { x = 0, y = 0 }; WIN_ACCESS.size = { x = 1, y = 1 }
frame('barefixed')
check('main closed', OPEN.main == false)
check('ui.dummy sets the window to 150% of 280x120', DUMMY[1] and DUMMY[1].x == 420 and DUMMY[1].y == 180, DUMMY[1] and (DUMMY[1].x .. 'x' .. DUMMY[1].y))
check('dummy comes before the background fill (content size first)', RECT[1].p2.x == 420 and RECT[1].p2.y == 180, RECT[1].p2.x .. 'x' .. RECT[1].p2.y)
check('at load nothing is handed over: it keeps its own remembered spot, no move/resize', WIN_ACCESS.pos.x == 0 and #WIN_ACCESS.moves == 0 and #WIN_ACCESS.resizes == 0, WIN_ACCESS.pos.x .. '/' .. #WIN_ACCESS.moves .. '/' .. #WIN_ACCESS.resizes)
check('saved size setting survives the load handoff (still 150%)', STORAGE.sizePct == 150, STORAGE.sizePct)
check('HUD laid out for 420x180', #RECT == 20 and #TEXT == 4)

print('== Hide resize handle from a dragged 560x240 main window keeps that size ==')
fresh(); setWindow(560, 240); frame('main', 2)
tick('Hide resize handle'); frame('main')
check('fixed asked to open', OPEN.fixed == true, openSet())
check('sizePct captured from the dragged size (200%)', STORAGE.sizePct == 200, STORAGE.sizePct)
WIN_ACCESS.name = 'IMGUI_LUA_Gear Speedo_fixed'; WIN_ACCESS.title = 'Gear Speedo (fixed size)'; frame('fixed')
check('fixed draws at 560x240', DUMMY[1].x == 560 and DUMMY[1].y == 240)
check('a window with a title bar draws no hover buttons', (function() HOVER = true; frame('fixed'); HOVER = false; return #ICONBTN == 0 end)())
tick('Hide resize handle')                       -- untick: back to main, carrying the size
frame('fixed')
check('main asked to open again', OPEN.main == true and OPEN.fixed == true, openSet())
WIN_ACCESS.name = 'IMGUI_LUA_Gear Speedo_main'; WIN_ACCESS.title = 'Gear Speedo'; WIN_ACCESS.moves, WIN_ACCESS.resizes = {}, {}
frame('main')
check('fixed closed, main resized to 560x240', OPEN.fixed == false and WIN_ACCESS.size.x == 560 and WIN_ACCESS.size.y == 240, openSet() .. ' ' .. WIN_ACCESS.size.x)

print('== the other window never opens (CSP ignored us): settle where we are ==')
fresh(); setWindow(280, 120); frame('main', 2)
local realSetOpen, realIsOpen = ac.setWindowOpen, ac.isWindowOpen
ac.setWindowOpen = function(id, v) OPEN_LOG[#OPEN_LOG + 1] = { id = id, open = v } end   -- accepted, but nothing opens
tick('Hide title bar'); frame('main', 130)
check('main kept drawing throughout', #RECT == 20)
check('setting reverted to match the window that is actually showing', STORAGE.hideTitle == false, STORAGE.hideTitle)
check('main was never closed', OPEN.main == true)
ac.setWindowOpen = realSetOpen

print('== very old CSP: no ac.setWindowOpen at all ==')
fresh(); ac.setWindowOpen = nil; ac.isWindowOpen = nil
tick('Hide title bar'); tick('Hide resize handle')
local ok, err = pcall(frame, 'main', 3)
check('no crash', ok, err)
check('HUD still drawn', #RECT == 20)
check('both boxes untick themselves: nothing can switch', STORAGE.hideTitle == false and STORAGE.hideGrip == false, tostring(STORAGE.hideTitle) .. '/' .. tostring(STORAGE.hideGrip))
ac.setWindowOpen, ac.isWindowOpen = realSetOpen, realIsOpen

print('== session restore opens main AND the wanted window together ==')
fresh(); STORAGE.hideTitle = true; OPEN = { main = true, bare = true }
frame('bare'); frame('main'); frame('bare'); frame('main')
check('surplus main closed, bare kept, nothing else touched', OPEN.main == false and OPEN.bare == true, openSet())
check('settings untouched', STORAGE.hideTitle == true)
frame('bare', 20); OPEN.main = true; frame('main')
check('and a later app-list click still closes everything', openSet() == '', openSet())

print('== a free-aspect drag: Hide resize handle keeps the drawn scale, not the width ==')
fresh(); setWindow(840, 60); frame('main', 2)      -- allowed by MIN/MAX, HUD drawn at scale 0.5
tick('Hide resize handle'); frame('main')
check('sizePct = 50 (the scale the HUD had), not 300 (the width)', STORAGE.sizePct == 50, STORAGE.sizePct)

print('== locked: the Size slider is parked ==')
fresh(); STORAGE.hideGrip = true; STORAGE.lockPos = true; STORAGE.sizePct = 120; OPEN = { fixed = true }
local sliders = {}
ui.slider = function(l, v) sliders[#sliders + 1] = l; return 999 end; ui.itemEdited = function() return true end
script.windowSettings(1 / 60); ui.slider = function(l, v) return v end; ui.itemEdited = function() return false end
check('no ##size slider while locked, size unchanged', (function() for _, l in ipairs(sliders) do if l == '##size' then return false end end return STORAGE.sizePct == 120 end)(), table.concat(sliders, ','))

print('== no ui.popup / accessor: bare window still works ==')
fresh(); STORAGE.hideTitle = true; OPEN = { bare = true }
local savedPopup, savedAccess = ui.popup, ac.accessAppWindow
ui.popup = nil; ac.accessAppWindow = nil
HOVER = true; CLICK[ui.Icons.Settings] = true
ok, err = pcall(frame, 'bare', 3)
check('no crash without ui.popup or accessor', ok, err)
CLICK = {}; HOVER = false; ui.popup = savedPopup; ac.accessAppWindow = savedAccess

print('== lock follows the window that is showing ==')
fresh(); STORAGE.hideTitle = true; OPEN = { bare = true }
WIN_ACCESS.name = 'IMGUI_LUA_Gear Speedo_bare'; WIN_ACCESS.title = 'Gear Speedo (no title bar)'; WIN_ACCESS.pos = { x = 300, y = 300 }; WIN_ACCESS.moves = {}
frame('bare', 2); tick('Lock position and size'); frame('bare')
check('captured the bare window\'s spot', STORAGE.lockX == 300)
WIN_ACCESS.pos = { x = 999, y = 999 }; frame('bare')
check('dragged bare window snapped back', WIN_ACCESS.pos.x == 300, WIN_ACCESS.pos.x)

print(('\n%d failure(s)'):format(fails)); os.exit(fails > 0 and 1 or 0)
