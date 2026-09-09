-- Settings probes: opacity, position lock, rev-bar toggle. Run: luajit verify/probe-settings.lua
local HERE = (arg and arg[0] or 'x'):match('^(.*)[/\\]') or '.'
local APP = HERE .. '/../apps/lua/GearSpeedo/GearSpeedo.lua'
dofile(HERE .. '/cspstub.lua')
dofile(APP)
local fails = 0
local function check(n, c, e) if c then print('  ok   '..n) else print('  FAIL '..n..' '..tostring(e)); fails = fails + 1 end end
local function frame(n) for _ = 1, (n or 1) do reset(); script.windowMain(1/60) end end
setWindow(280, 120); CAR.gear, CAR.rpm, CAR.rpmLimiter, CAR.speedKmh = 3, 4000, 7500, 120

print('== unlocked: dragging is left alone ==')
frame(3)
WIN_ACCESS.pos = {x = 400, y = 300}; frame(3)
check('no moves issued while unlocked', #WIN_ACCESS.moves == 0, #WIN_ACCESS.moves)
check('accessor not even looked up while unlocked', #ACCESS_CALLS == 0, #ACCESS_CALLS)

print('== player ticks Lock in settings ==')
ui.checkbox = function(label, v) return label == 'Lock position and size' end
script.windowSettings(1/60)
ui.checkbox = function() return false end
check('lockPos set', STORAGE.lockPos == true)
check('capture pending (-1)', STORAGE.lockX == -1)
frame(1)
check('first locked frame captures current spot 400,300', STORAGE.lockX == 400 and STORAGE.lockY == 300, STORAGE.lockX..','..STORAGE.lockY)
check('and current size 280x120', STORAGE.lockW == 280 and STORAGE.lockH == 120, STORAGE.lockW..'x'..STORAGE.lockH)
check('found window under its display name first', ACCESS_CALLS[1] == 'Gear Speedo', ACCESS_CALLS[1])

print('== someone drags it while locked ==')
WIN_ACCESS.pos = {x = 650, y = 80}; frame(1)
check('moved straight back to 400,300', WIN_ACCESS.pos.x == 400 and WIN_ACCESS.pos.y == 300, WIN_ACCESS.pos.x..','..WIN_ACCESS.pos.y)
check('exactly one move call', #WIN_ACCESS.moves == 1, #WIN_ACCESS.moves)
frame(5)
check('no further moves when already in place', #WIN_ACCESS.moves == 1, #WIN_ACCESS.moves)

print('== someone resizes it while locked ==')
WIN_ACCESS.size = {x = 560, y = 240}; frame(1)
check('resized back to 280x120', WIN_ACCESS.size.x == 280 and WIN_ACCESS.size.y == 120, WIN_ACCESS.size.x..'x'..WIN_ACCESS.size.y)
check('one resize call', #WIN_ACCESS.resizes == 1, #WIN_ACCESS.resizes)

print('== sub-pixel jitter is ignored ==')
WIN_ACCESS.pos = {x = 400.3, y = 300.2}; frame(1)
check('no move for a 0.3px wobble', #WIN_ACCESS.moves == 1, #WIN_ACCESS.moves)

print('== untick Lock: dragging works again ==')
ui.checkbox = function(label, v) return label == 'Lock position and size' end
script.windowSettings(1/60); ui.checkbox = function() return false end
check('lockPos cleared and capture reset', STORAGE.lockPos == false and STORAGE.lockX == -1)
WIN_ACCESS.pos = {x = 10, y = 10}; frame(3)
check('window stays where the player put it', WIN_ACCESS.pos.x == 10, WIN_ACCESS.pos.x)

print('== re-lock captures the NEW spot, not the old one ==')
ui.checkbox = function(label, v) return label == 'Lock position and size' end
script.windowSettings(1/60); ui.checkbox = function() return false end
frame(1)
check('captured 10,10', STORAGE.lockX == 10 and STORAGE.lockY == 10, STORAGE.lockX..','..STORAGE.lockY)

print('== CSP registers the window under a name we did not guess ==')
WIN_ACCESS.name = 'something-else'; ownWindowCacheReset = nil
-- fresh app instance to clear the cached accessor
dofile(APP)
STORAGE.lockPos = true; STORAGE.lockX = -1
ACCESS_CALLS = {}; WIN_ACCESS.moves = {}
local ok, err = pcall(frame, 3)
check('no crash', ok, err)
check('tried all four candidate names', #ACCESS_CALLS == 4, #ACCESS_CALLS)
check('no moves (nothing to move)', #WIN_ACCESS.moves == 0)
frame(200)
check('retries later rather than giving up forever', #ACCESS_CALLS >= 8, #ACCESS_CALLS)

print('== older CSP: accessor exists but has no move() ==')
WIN_ACCESS.name = 'Gear Speedo'
dofile(APP)
STORAGE.lockPos = true; STORAGE.lockX = -1
local realAccess = ac.accessAppWindow
ac.accessAppWindow = function(n) local a = realAccess(n); if a then a.move = nil; a.resize = nil end; return a end
frame(1); WIN_ACCESS.pos = {x = 999, y = 999}
ok, err = pcall(frame, 2)
check('no crash without move()', ok, err)
check('HUD still drew (rects > 1)', #RECT > 1, #RECT)
ac.accessAppWindow = realAccess

print('== no accessor API at all (very old CSP) ==')
local saved = ac.accessAppWindow; ac.accessAppWindow = nil
dofile(APP)
STORAGE.lockPos = true; STORAGE.lockX = -1
ok, err = pcall(frame, 2)
check('no crash with ac.accessAppWindow missing', ok, err)
ac.accessAppWindow = saved

print('== RPM bar toggle ==')
dofile(APP)
CAR.rpm = 7200; frame(1)   -- 96% of 7500: past the 95% shift point
local function barRects() local n = 0; for _, r in ipairs(RECT) do if math.abs(r.p2.y - r.p1.y - 12) < 0.01 then n = n + 1 end end; return n end
check('bar drawn by default: 18 segments', barRects() == 18, barRects())
ui.checkbox = function(label, v) return label == 'Show RPM bar' end
script.windowSettings(1/60); ui.checkbox = function() return false end
frame(1)
check('bar hidden: 0 segments', barRects() == 0, barRects())
check('background still first', RECT[1].p1.x == 0 and RECT[1].p2.x == 280)
check('gear and speed still drawn', #TEXT == 4, #TEXT)
local gearRed = false
for _, t in ipairs(TEXT) do if t.text == '3' and t.col.r > 0.9 and t.col.g < 0.3 then gearRed = true end end
check('gear still goes red at the shift point with the bar hidden', gearRed)
check('fonts balanced', #FONTS == 0)

print('== background opacity ==')
setWindow(560, 240); CAR.gear, CAR.rpm, CAR.speedKmh, CAR.rpmLimiter = 3, 4000, 120, 7500
reset(); script.windowMain(0.016)
local bg = RECT[1]
print(("  " .. 'first draw call: rect (%g,%g)-(%g,%g) rgba(%g,%g,%g,%g)  covers window: %s'):format(
  bg.p1.x, bg.p1.y, bg.p2.x, bg.p2.y, bg.col.r, bg.col.g, bg.col.b, bg.col.a,
  tostring(bg.p1.x == 0 and bg.p1.y == 0 and bg.p2.x == 560 and bg.p2.y == 240)))
-- a player drags the Background slider to 25 in the settings window
ui.slider = function(label, v) return label == '##opacity' and 25 or v end
ui.itemEdited = function() return true end
script.windowSettings(0.016)
reset(); script.windowMain(0.016)
print(("  " .. 'after slider -> 25: background alpha = %g'):format(RECT[1].col.a))
ui.slider = function(label, v) return label == '##opacity' and 0 or v end
script.windowSettings(0.016); reset(); script.windowMain(0.016)
print(("  " .. 'slider -> 0: alpha = %g (fully see-through, HUD still drawn: %d rects, %d texts)'):format(RECT[1].col.a, #RECT, #TEXT))
-- car nil during session load: background still painted, nothing else
CAR_NIL = true; reset(); script.windowMain(0.016)
print(("  " .. 'car nil: rects=%d (just the background), texts=%d'):format(#RECT, #TEXT))
print(('\n%d failure(s)'):format(fails)); os.exit(fails > 0 and 1 or 0)
