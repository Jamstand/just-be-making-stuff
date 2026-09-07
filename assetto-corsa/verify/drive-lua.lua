-- Fresh scripted session under LuaJIT (CSP's runtime family), with probes.
local HERE = (arg and arg[0] or 'x'):match('^(.*)[/\\]') or '.'
dofile(HERE .. '/cspstub.lua')
dofile(HERE .. '/../apps/lua/GearSpeedo/GearSpeedo.lua')
print('runtime: ' .. (jit and jit.version or _VERSION))

local function frame(dt) reset(); script.windowMain(dt or 0.016) end
local function text(t) for _, x in ipairs(TEXT) do if x.text == t then return x end end end
local function lit() local n=0 for _,r in ipairs(RECT) do if math.abs(r.p2.y-r.p1.y-12*(WINSCALE or 1))<0.5 and r.col.a>=0.9 then n=n+1 end end return n end
local function hud()
  -- classify big texts by where their box sits: left half = gear, right = speed
  local g, sp, u
  for _, x in ipairs(TEXT) do
    local cx = (x.p1.x + x.p2.x) / 2
    if x.text == 'KM/H' or x.text == 'MPH' then u = x.text
    elseif x.size > 30 then
      if cx < 150 then g = x.text else sp = x.text end
    end
  end
  return ('gear=%-2s speed=%-4s %-4s bar=%2d/18'):format(tostring(g), tostring(sp), tostring(u), lit())
end

print('\n== session: 8-speed car (Porsche PDK style), limiter 9000 ==')
CAR.rpmLimiter = 9000
for _, st in ipairs{
  {0,   800,   0, 'neutral, idle'},
  {1,  3200,  22, '1st'},
  {2,  6500,  71, '2nd'},
  {5,  7100, 178, '5th'},
  {7,  8300, 262, '7th'},
  {8,  8950, 301, '8th, on the shift point'},
  {-1, 1500,   6, 'reverse'},
} do
  CAR.gear, CAR.rpm, CAR.speedKmh = st[1], st[2], st[3]
  frame(); print(('  %-26s %s'):format(st[4], hud()))
end

print('\n== car swap mid-session: limiter drops 9000 -> 6500, same rpm ==')
CAR.gear, CAR.rpm, CAR.speedKmh = 3, 6000, 120
CAR.rpmLimiter = 9000; frame(); local before = lit()
CAR.rpmLimiter = 6500; frame(); local after = lit()
print(('  bar %d/18 -> %d/18 (should jump up, limit is now lower)'):format(before, after))
assert(after > before, 'bar did not react to new rpmLimiter')

print('\n== settings window: click through every control ==')
-- Script the stub so controls "get clicked" in sequence.
local clicks = {['Show speed']=true, ['Use MPH']=true}
ui.checkbox = function(label, v) local c = clicks[label]; clicks[label] = false; return c end
ui.slider = function(_, v) return 88 end
ui.itemEdited = function() return true end
script.windowSettings(0.016)
print('  (settings is file-local; its effect is read off the next frame instead)')

print('\n== the widget reflects those settings on the next frame ==')
CAR.gear, CAR.rpm, CAR.speedKmh, CAR.rpmLimiter = 4, 5000, 160.9, 8000
frame(); print('  ' .. hud())
local speedTexts = {} for _,x in ipairs(TEXT) do if tonumber(x.text) and x.size > 30 then speedTexts[#speedTexts+1]=x.text end end
print('  large numeric texts drawn: ' .. table.concat(speedTexts, ', ') .. '  (speed hidden -> only the gear)')
local gearBox
for _,x in ipairs(TEXT) do if x.text=='4' then gearBox = x end end
print(('  gear box centre x = %.1f of %d (centred when speed hidden)'):format((gearBox.p1.x+gearBox.p2.x)/2, 280))

-- turn speed back on, keep mph, check conversion
ui.checkbox = function(label, v) return label == 'Show speed' end
script.windowSettings(0.016)
frame()
print('  ' .. hud() .. '   <- 160.9 km/h should read 99 or 100 mph')
print('  shift point now 88%: rpm 5000/8000 = 62% -> flashing? ' .. tostring(lit() == 18))
CAR.rpm = 7100 -- 88.75%
local flashed = false
for i=1,30 do frame(0.05); for _,r in ipairs(RECT) do if r.col.a>=0.9 and r.col.r==1 and r.col.g==1 and r.col.b==1 then flashed=true end end end
print('  rpm 7100/8000 = 88.75% with shiftAt 88 -> flashes: ' .. tostring(flashed))

print('\n== manifest window bounds: MIN 140x60, MAX 840x360 ==')
for _, wh in ipairs{{140,60},{840,360}} do
  setWindow(wh[1], wh[2]); frame()
  local mx,my,mnx,mny = 0,0,1e9,1e9
  for _,r in ipairs(RECT) do mx=math.max(mx,r.p2.x); my=math.max(my,r.p2.y); mnx=math.min(mnx,r.p1.x); mny=math.min(mny,r.p1.y) end
  for _,t in ipairs(TEXT) do mx=math.max(mx,t.p2.x); my=math.max(my,t.p2.y); mnx=math.min(mnx,t.p1.x); mny=math.min(mny,t.p1.y) end
  print(('  %dx%d: content spans x %.0f..%.0f  y %.0f..%.0f  -> inside: %s'):format(
    wh[1],wh[2],mnx,mx,mny,my, tostring(mnx>=0 and mny>=0 and mx<=wh[1]+0.5 and my<=wh[2]+0.5)))
end
setWindow(280,120)

print('\n== probes ==')
CAR.gear = 12; frame(); print('  gear 12 (nonsense) -> label ' .. tostring(text('12') and '12' or '?'))
CAR.gear = 3; CAR.speedKmh = 999.99; frame(); print('  999.99 km/h -> ' .. hud())
CAR.speedKmh = 0/0; local ok, err = pcall(frame); print('  speed NaN -> survives: ' .. tostring(ok) .. (ok and '' or ' ' .. tostring(err)))
CAR.speedKmh = 100; CAR.rpm = 0/0; ok, err = pcall(frame); print('  rpm NaN   -> survives: ' .. tostring(ok) .. (ok and '' or ' ' .. tostring(err)))
CAR.rpm = 5000; CAR.rpmLimiter = -100; ok, err = pcall(frame); print('  limiter negative -> survives: ' .. tostring(ok))
CAR.rpmLimiter = 8000; frame(0); print('  dt=0 frame -> ok, bar ' .. lit() .. '/18')
frame(10); print('  dt=10s frame -> ok, bar ' .. lit() .. '/18')
print('  fonts balanced: ' .. tostring(#FONTS == 0))
