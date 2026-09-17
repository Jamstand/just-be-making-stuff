#!/usr/bin/env python3
"""Smoke-test a CSP Lua app folder (manifest.ini + <Name>.lua) without Assetto Corsa.

  python3 run_app.py <app folder> [--quiet]

1. Static check: every ac./ui./web./io./os./render./physics./math./table./string./vec2./vec3./rgbm.
   identifier used by the script must exist in the CSP 0.2.11 SDK index (function or enum key).
2. Manifest check: [ABOUT], [CORE], at least one [WINDOW_...] whose FUNCTION_MAIN / FUNCTION_SETTINGS
   name a `script.<fn>` the file defines.
3. Dynamic check: run every window function for many frames under LuaJIT in several simulated sessions
   (offline day, online night with 12 cars, paused, replay, no music, web failures). Any Lua error fails.
Exit code 0 = pass.
"""
import sys, os, re, json, configparser, traceback
from lupa.luajit21 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
IDX = json.load(open(os.path.join(HERE, 'sdk_index.json')))
STD = {  # standard Lua 5.1 / LuaJIT members that are not in the SDK index
    'math': 'abs acos asin atan atan2 ceil cos cosh deg exp floor fmod frexp huge ldexp log log10 max min modf pi pow rad random randomseed sin sinh sqrt tan tanh'.split(),
    'string': 'byte char dump find format gmatch gsub len lower match rep reverse sub upper'.split(),
    'table': 'concat insert maxn remove sort unpack pack'.split(),
    'os': 'clock date difftime exit getenv time tmpname'.split(),
    'io': 'read write lines open close'.split(),
    'bit': 'band bor bxor bnot lshift rshift arshift rol ror tobit tohex bswap'.split(),
}
EXTRA_OK = {'rgbm.colors', 'rgbm.new', 'rgbm.tmp', 'rgb.new', 'vec2.new', 'vec2.tmp', 'vec3.new', 'vec3.tmp', 'vec2.isvec2', 'vec3.isvec3',
            'ui.Icons', 'ac.StructItem', 'stringify.tryParse', 'stringify.parse', 'JSON.parse', 'JSON.stringify', 'ui.DWriteFont'}

def static_check(src):
    problems = set()
    for m in re.finditer(r'\b(ac|ui|web|io|os|render|physics|math|table|string|stringify|JSON|vec2|vec3|vec4|rgbm|rgb|hsv|bit)\.([A-Za-z_]\w*)(?:\.([A-Za-z_]\w*))?', src):
        ns, member, sub = m.group(1), m.group(2), m.group(3)
        full = f'{ns}.{member}'
        if full in EXTRA_OK or member in STD.get(ns, []) or full in IDX['classes']: continue
        if full in IDX['functions']:
            continue
        if full in IDX['enums']:
            if sub and sub not in IDX['enums'][full]: problems.add(f'{full}.{sub} (enum key not in SDK; keys: {", ".join(IDX["enums"][full][:12])}...)')
            continue
        if any(k.startswith(full + '.') for k in IDX['functions']):  # namespace table like ac.StructItem
            continue
        problems.add(full)
    return sorted(problems)

def read_manifest(folder):
    raw = open(os.path.join(folder, 'manifest.ini'), encoding='utf-8').read()
    windows, section, about, core = [], None, {}, {}
    for line in raw.splitlines():
        line = line.split(';')[0].strip()
        if not line: continue
        m = re.match(r'^\[(.+)\]$', line)
        if m:
            section = m.group(1)
            if section.startswith('WINDOW_'): windows.append({})
            continue
        if '=' not in line: continue
        k, v = [x.strip() for x in line.split('=', 1)]
        if section == 'ABOUT': about[k] = v
        elif section == 'CORE': core[k] = v
        elif section and section.startswith('WINDOW_'): windows[-1][k] = v
    return about, core, windows

def make_runtime(scenario):
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute(open(os.path.join(HERE, 'stubs.lua'), encoding='utf-8').read())
    L.execute(open(os.path.join(HERE, 'auto_stubs.lua'), encoding='utf-8').read())
    L.execute(SCENARIO_LUA)
    # lupa hands Python dicts/lists to Lua as userdata (missing keys raise KeyError, ipairs fails);
    # convert to real Lua tables so `s.w or 260` and `ipairs(s.files or {})` behave.
    lua_scn = L.table_from({k: (L.table_from(v) if isinstance(v, list) else v) for k, v in scenario.items()})
    L.globals().setupScenario(lua_scn)
    return L

SCENARIO_LUA = r'''
function setupScenario(s)
  _H.ui.windowSize = vec2(s.w or 260, s.h or 200)
  _H.ui.state = { dt = 0.016, windowSize = vec2(1920, 1080), uiScale = 1, appsHidden = false }
  _H.trackName, _H.trackID, _H.ppFilter = s.track or 'Shutoko Revival Project', s.trackID or 'shuto_revival_project_beta', s.ppFilter or 'JamPure_Cinematic'
  _H.folders = { [ac.FolderID.Root] = '/ac', [ac.FolderID.PPFilters] = '/ac/system/cfg/ppfilters', [ac.FolderID.ExtRoot] = '/ac/extension', [ac.FolderID.ExtCfgUser] = '/ac/extension/config', [ac.FolderID.ACApps] = '/ac/apps', [ac.FolderID.ScriptOrigin] = '/ac/apps/lua/App', [ac.FolderID.Cfg] = '/ac/cfg' }
  _H.files = {}; for _, f in ipairs(s.files or {}) do _H.files[f] = true end
  _H.dirs = {}; for _, d in ipairs(s.dirs or {}) do _H.dirs[d] = true end
  _H.sunAngle = s.sunAngle or 45
  _H.music = { isPlaying = s.musicPlaying == true, hasCover = false, title = s.musicPlaying and 'Midnight City' or '', artist = s.musicPlaying and 'M83' or '', album = '', sourceID = 'spotify', albumTracksCount = 0, trackNumber = 0, trackDuration = 245, trackPosition = 61 }
  _H.sim = { carsCount = s.cars or 1, focusedCar = 0, closelyFocusedCar = 0, dt = s.paused and 0 or 0.016, time = 0, gameTime = 0, systemTime = 1700000000, frame = 0,
    isOnlineRace = s.online == true, isReplayActive = s.replay == true, isReplayOnlyMode = false, isPaused = s.paused == true, isInMainMenu = false, isVRConnected = false, isVRMode = false,
    isPostProcessingActive = true, isLinearColorSpaceActive = s.lcs == true, isFSRActive = true, isTripleMode = false, isFullscreen = true, isVSyncActive = false, msaaSamples = 4, worldDetailLevel = 5,
    cameraExposure = s.exposure or 0.31, exposureMultiplier = 1.0, cameraPosition = vec3(0, 2, -5), cameraLook = vec3(0, 0, 1), cameraUp = vec3(0, 1, 0), cameraSide = vec3(1, 0, 0), cameraFOV = 56,
    windowWidth = 2560, windowHeight = 1440, windowSize = vec2(2560, 1440), ambientTemperature = 24, roadTemperature = 31, rainIntensity = s.rain or 0, rainWetness = 0, rainWater = 0,
    weatherType = 15, timeHours = s.timeHours or 14.5, timeMinutes = 0, timeSeconds = 0, dayOfYear = 200, timestamp = 1700000000, raceSessionType = 1, currentSessionIndex = 0, sessionsCount = 1,
    trackLengthM = 42000, isSessionStarted = true, isTimedRace = false, raceFlagType = 0, sessionTimeLeft = 3600000, isCarResetAllowed = true, speedLimitKmh = 0, cars = {} }
  _H.sessions = { { type = 1, name = 'Practice', laps = 0, durationMinutes = 60, isTimedRace = false, startTime = 0 } }
  _H.cars = {}
  for i = 0, (s.cars or 1) - 1 do
    local ahead = (i % 3 == 0)
    local car = { index = i, nodeIndex = i, position = vec3(i == 0 and 0 or (i * 7 - 40), 0, i == 0 and 0 or (ahead and i * 25 or -i * 18)), velocity = vec3(0, 0, 30 + i), look = vec3(0, 0, 1), up = vec3(0, 1, 0), side = vec3(1, 0, 0),
      speedKmh = 108 + i * 3, speedMs = 30 + i, gear = 4, rpm = 3800 + i * 100, rpmLimiter = 7000, fuel = 38.5, maxFuel = 59, fuelPerLap = 0, gas = 0.4, brake = 0, clutch = 0, steer = 2, handbrake = 0,
      turboBoost = 0.4, drivetrainSpeed = 108, wheelsOutside = 0, engineLifeLeft = 1000, damage = { 0, 0, 0, 0, 0 }, splinePosition = (0.1 + i * 0.03) % 1, lapCount = 2, racePosition = i + 1,
      isActive = true, isConnected = i ~= 5, isRemote = i ~= 0 and s.online == true, isAIControlled = i ~= 0 and not s.online, isCameraOnBoard = i == 0, isInPitlane = false, isInPit = false,
      headlightsActive = s.sunAngle and s.sunAngle < 0, focusedOnInterior = true, isHidingLabels = i == 5, lowBeams = true, highBeams = false, extraA = false, kersCharge = 0, batteryVoltage = 12.6,
      compass = 30 + i * 10, absMode = 1, absModes = 3, tcMode = 1, tcModes = 3, autoShift = false, hasTurbo = true, turboCount = 1, waterTemperature = 92, oilTemperature = 98, collidedWith = -1,
      lapTimeMs = 95000 + i * 1000, bestLapTimeMs = 94000, previousLapTimeMs = 96000, lastLapTimeMs = 96000, distanceDrivenSessionKm = 12.3 + i, distanceDrivenTotalKm = 800 + i, turningLeftLights = false, turningRightLights = false, hazardLights = false,
      isEngineLimiterOn = false, drsActive = false, isRacingCar = false, isGearGrinding = false, wheels = {}, __driverName = i == 0 and 'vans' or ('Driver ' .. i), __carName = i == 0 and 'BMW M340i' or ('Car ' .. i), __carID = i == 0 and 'bmw_m340i' or ('car_' .. i) }
    for w = 0, 3 do car.wheels[w] = { tyreCoreTemperature = 80, tyrePressure = 27, slip = 0, load = 4000, ndSlip = 0.2, tyreWear = 0.01, isBlown = false } end
    _H.cars[#_H.cars + 1] = car
    _H.sim.cars[i] = car
  end
  _H.web.handler = function(r)
    if s.webFail then return 'connection refused', nil end
    local body = '{}'
    if r.url:find('/widget%-events/recent') then body = '{"seq":7,"events":[{"seq":6,"t":1700000000000,"event":"follow","data":{"name":"newviewer"}},{"seq":7,"t":1700000001000,"event":"sub","data":{"name":"someone","tier":"1000","gift":false}}]}'
    elseif r.url:find('/now%-playing') then body = '{"playing":true,"title":"Kids","artist":"MGMT","album":"Oracular Spectacular","albumArt":null,"duration":300000,"progress":120000,"id":"x"}'
    elseif r.url:find('/twitch/stream%-status') then body = '{"live":true,"channel":"vans_it","game":"Assetto Corsa","viewers":42,"followers":1200,"uptime":"1:23:45"}'
    elseif r.url:find('/ac/telemetry') then body = '{"ok":true}' end
    return nil, { status = 200, body = body, headers = { ['content-type'] = 'application/json' } }
  end
end
'''

SCENARIOS = [
    dict(name='offline day, single car'),
    dict(name='online night, 12 cars, music, rain', cars=12, online=True, sunAngle=-8, musicPlaying=True, rain=0.3, timeHours=22.5),
    dict(name='paused, replay, web failing', cars=4, paused=True, replay=True, webFail=True),
    dict(name='tiny window, LCS, no pp script file', w=90, h=60, lcs=True, cars=3),
    dict(name='script present on disk', files=['/ac/system/cfg/ppfilters/pure_scripts/JamPure_Cinematic.lua', '/ac/system/cfg/ppfilters/JamPure_Cinematic.ini'], dirs=['/ac/system/cfg/ppfilters/pure_scripts']),
]

def run(folder, quiet=False):
    name = os.path.basename(os.path.normpath(folder))
    lua_path = os.path.join(folder, name + '.lua')
    if not os.path.exists(lua_path):
        luas = [f for f in os.listdir(folder) if f.endswith('.lua')]
        if len(luas) == 1: lua_path = os.path.join(folder, luas[0])
        else: print(f'FAIL {name}: expected {name}.lua'); return False
    src = open(lua_path, encoding='utf-8').read()
    ok = True
    unknown = static_check(src)
    if unknown:
        ok = False; print(f'FAIL {name}: unknown API identifiers: ' + ', '.join(unknown))
    about, core, windows = read_manifest(folder)
    for key in ('NAME', 'AUTHOR', 'VERSION', 'DESCRIPTION'):
        if key not in about: ok = False; print(f'FAIL {name}: manifest [ABOUT] missing {key}')
    if not windows: ok = False; print(f'FAIL {name}: manifest has no [WINDOW_...] section')
    fns = []
    for w in windows:
        for key in ('ID', 'NAME', 'FUNCTION_MAIN', 'SIZE'):
            if key not in w: ok = False; print(f'FAIL {name}: window missing {key}')
        for key in ('FUNCTION_MAIN', 'FUNCTION_SETTINGS'):
            if key in w: fns.append(w[key])
    if not ok: return False
    for scenario in SCENARIOS:
        try:
            L = make_runtime(scenario)
            L.execute(src)
            g = L.globals()
            script = g.script
            if script is None: raise RuntimeError('script table not defined')
            for fn in fns:
                if script[fn] is None: raise RuntimeError(f'script.{fn} named in manifest but not defined')
            for frame in range(150):
                for fn in fns:
                    script[fn](0.016)
                g._H.tick(0.016)
                if frame % 10 == 3: g._H.resolveWeb()
            st = g._H.uiState
            if st.fontStack and len(st.fontStack) > 0: raise RuntimeError('font stack not balanced (pushFont without popFont)')
            if (st.styleDepth or 0) != 0 or (st.varDepth or 0) != 0: raise RuntimeError('style stack not balanced')
            if st.groupDepth != 0 or st.childDepth != 0: raise RuntimeError('group/child not balanced')
            calls = dict(g._H.ui.calls.items()) if g._H.ui.calls else {}
            web = [r.url for r in g._H.web.done.values()] if g._H.web.done else []
            if not quiet: print(f'  ok  [{scenario["name"]}] draw calls: {sum(calls.values())} ({", ".join(k for k in sorted(calls))}); web: {len(web)}' + (f' e.g. {web[0]}' if web else ''))
        except Exception as e:
            ok = False
            msg = str(e).split('stack traceback')[0].strip()
            print(f'FAIL {name} [{scenario["name"]}]: {msg[:600]}')
    print(('PASS ' if ok else 'FAIL ') + name)
    return ok

if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    results = [run(a, '--quiet' in sys.argv) for a in args]
    sys.exit(0 if all(results) else 1)
