"""A scripted drive session against the real GearSpeedo.py: launch, a lap of
gear changes up to the limiter, settings interaction, then hostile probes.
Prints a timeline of what the widget showed."""
import sys, os, shutil, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
# Drive a scratch COPY of the app: it writes SCALE back into its own ini when
# the spinner moves, and that must not land in the repo.
SCRATCH = tempfile.mkdtemp(prefix='gearspeedo-')
shutil.copytree(os.path.join(HERE, '..', 'apps', 'python', 'GearSpeedo'),
                os.path.join(SCRATCH, 'GearSpeedo'))
sys.path.insert(0, HERE)                                 # mock ac / acsys
sys.path.insert(0, os.path.join(SCRATCH, 'GearSpeedo'))  # the app copy
import ac, acsys
import GearSpeedo as G

def tick(n=1, dt=0.016):
    for _ in range(n): G.acUpdate(dt)

def hud():
    bar = int(G._rpm_fraction * G.BAR_SEGMENTS + 1e-4)
    return "gear=%-2s speed=%-4s bar=%2d/18 redline=%-6d shift=%d" % (
        ac.LABELS[G.label_gear], ac.LABELS[G.label_speed], bar,
        G._redline, G._shift)

print("== session start ==")
print("acMain ->", repr(G.acMain(1.0)))
print("import-marker logged:", any("module imported" in l for l in ac.LOG))
print("loaded logged:       ", any("loaded" in l for l in ac.LOG))

print("\n== pull away and drive a lap (mx5, ~7500 limiter) ==")
ac.STATE['car'] = 'ks_mazda_mx5'
lap = [  # (gear_raw, rpm, kmh, note)
    (1,  900,   0, "idling in neutral"),
    (2, 2500,  15, "1st, pulling away"),
    (2, 6000,  48, "1st, winding out"),
    (3, 4400,  62, "into 2nd"),
    (3, 7100,  95, "2nd, near the top"),
    (4, 5600, 118, "3rd"),
    (5, 6200, 158, "4th"),
    (6, 7480, 205, "5th, just under the limiter"),
]
for gear, rpm, kmh, note in lap:
    ac.STATE.update(gear=gear, rpm=rpm, kmh=kmh, limiter=0)
    tick(3)
    print("  %-28s %s" % (note, hud()))

print("\n== bounce off the limiter ==")
ac.STATE.update(gear=6, rpm=7520, kmh=208, limiter=1)
tick(3)
print("  %-28s %s" % ("limiter cuts in", hud()))
ac.STATE.update(rpm=7000, limiter=0)
tick(3)
print("  %-28s %s" % ("limiter released", hud()))
ac.STATE.update(gear=7, rpm=6200, kmh=228)
tick(3)
print("  %-28s %s" % ("6th gear", hud()))

print("\n== box, reverse out of the pit spot ==")
ac.STATE.update(gear=0, rpm=1400, kmh=3)
tick(3)
print("  %-28s %s" % ("reverse", hud()))

print("\n== player opens the size strip and scales to 150%% ==")
ac.user_clicks(G.button_settings)
print("  strip visible:", ac.VISIBLE[G.spinner_scale] == 1,
      " window h:", ac.WINDOW['h'])
ac.user_sets_spinner(G.spinner_scale, 150)
tick(1)
print("  scale now:", G._scale, " window:", ac.WINDOW['w'], "x", ac.WINDOW['h'])
ini = open(os.path.join(SCRATCH, 'GearSpeedo', 'GearSpeedo.ini')).read()
line = [l for l in ini.splitlines() if l.startswith('SCALE')][0]
print("  ini now says:", line)
ac.user_clicks(G.button_settings)
print("  strip closed:", ac.VISIBLE[G.spinner_scale] == 0)

print("\n== PROBES ==")

print("probe: getCarName returns -1 (documented failure mode)")
ac.STATE['car'] = -1
tick(70, dt=0.02)   # crosses the 1s housekeeping tick
print("  survived:", not any("acUpdate failed" in l for l in ac.LOG),
      "| redline kept:", G._redline)
ac.STATE['car'] = 'ks_ferrari_f40'
tick(70, dt=0.02)
print("  car swap to str still detected (redline reset):",
      not G._limiter_confirmed)

print("probe: absurd telemetry")
ac.STATE.update(gear=50, rpm=1e9, kmh=9999.9, limiter=0)
tick(3)
print("  gear 50 shows: %r  bar clamped: %d/18  speed: %r" % (
    ac.LABELS[G.label_gear],
    int(G._rpm_fraction * G.BAR_SEGMENTS + 1e-4),
    ac.LABELS[G.label_speed]))
ac.STATE.update(gear=-3, rpm=-500.0, kmh=-8.0)
tick(3)
print("  gear -3 shows: %r  rpm -500 -> bar %d/18  speed %r" % (
    ac.LABELS[G.label_gear],
    int(G._rpm_fraction * G.BAR_SEGMENTS + 1e-4),
    ac.LABELS[G.label_speed]))

print("probe: hammer the spinner 60x in one tick burst")
for v in range(50, 201, 10) * 3 if hasattr(__builtins__, 'xrange') else list(range(50, 201, 10)) * 4:
    ac.user_sets_spinner(G.spinner_scale, v)
tick(1)
print("  final scale:", G._scale, "| no failures:",
      not any("failed" in l for l in ac.LOG))

print("probe: render at every state we ended in")
ac.QUADS[:] = []
G.on_render(0.016)
print("  render ok, quads drawn:", len(ac.QUADS),
      "| no render errors:", not any("render failed" in l for l in ac.LOG))

print("\n== full ac.LOG (what py_log.txt would contain) ==")
for l in ac.LOG: print("  |", l)
