"""Mock of AC's built-in `ac` module: records calls, feeds scripted telemetry."""
import acsys

STATE = {'gear': 1, 'rpm': 0.0, 'limiter': 0, 'kmh': 0.0, 'mph': 0.0,
         'car': 'ks_mazda_mx5'}
LOG = []
QUADS = []
LABELS = {}
_next_id = [1]

def _nid():
    _next_id[0] += 1
    return _next_id[0]

def log(s):
    assert isinstance(s, str), "ac.log requires a str"
    LOG.append(s)

def console(s): LOG.append(s)

WINDOWS = set()
def newApp(name):
    assert isinstance(name, str)
    i = _nid(); WINDOWS.add(i); return i

TITLES = {}
def setTitle(c, t):
    assert isinstance(t, str); TITLES[c] = t; return 1
WINDOW = {'w': 0, 'h': 0, 'opacity': 1.0}
CTRL_SIZE = {}
def setSize(c, w, h):
    if c in WINDOWS:
        WINDOW['w'], WINDOW['h'] = w, h
    else:
        CTRL_SIZE[c] = (w, h)
    return 1
def setPosition(c, x, y):
    if c in PROPS: PROPS[c]['pos'] = (x, y)
    return 1
ICON_MOVED = set()
def setIconPosition(c, x, y):
    if x < -1000 or y < -1000: ICON_MOVED.add(c)
    return 1
def drawBorder(c, v): return 1
def setBackgroundOpacity(c, v):
    assert 0.0 <= v <= 1.0, "opacity out of range: %r" % v
    WINDOW['opacity'] = v
    return 1
def addRenderCallback(c, fn): return 1

PROPS = {}
def addLabel(c, text):
    i = _nid(); LABELS[i] = text
    PROPS[i] = {'pos': (0, 0), 'size': 12, 'align': 'left', 'color': (1, 1, 1, 1)}
    return i
def setText(c, t):
    assert c in LABELS, "setText on unknown label %r" % c
    assert isinstance(t, str); LABELS[c] = t; return 1
def setFontSize(c, s):
    if c in PROPS: PROPS[c]['size'] = s
    return 1
def setFontAlignment(c, a):
    assert a in ("left", "right", "center"), "bad alignment %r" % a
    if c in PROPS: PROPS[c]['align'] = a
    return 1
def setFontColor(c, r, g, b, a):
    for v in (r, g, b, a):
        assert 0.0 <= v <= 1.0, "colour component out of range: %r" % v
    if c in PROPS: PROPS[c]['color'] = (r, g, b, a)
    return 1

def getCarName(i): return STATE['car']

def getCarState(car, what, *rest):
    if what == acsys.CS.Gear: return STATE['gear']
    if what == acsys.CS.RPM: return STATE['rpm']
    if what == acsys.CS.IsEngineLimiterOn: return STATE['limiter']
    if what == acsys.CS.SpeedKMH: return STATE['kmh']
    if what == acsys.CS.SpeedMPH: return STATE['mph']
    raise AssertionError("unexpected getCarState id %r" % what)

def glColor4f(r, g, b, a):
    for v in (r, g, b, a):
        assert 0.0 <= v <= 1.0, "glColor4f out of range: %r" % v
    _cur[0] = (r, g, b, a)
def glQuad(x, y, w, h):
    assert w >= 0 and h >= 0, "negative quad size"
    QUADS.append((x, y, w, h, _cur[0]))
_cur = [(0, 0, 0, 0)]
def glBegin(p): pass
def glEnd(): pass


# --- controls -------------------------------------------------------------
SPINNERS = {}
BUTTONS = {}
LISTENERS = {}
VISIBLE = {}

def addSpinner(c, label):
    assert isinstance(label, str)
    i = _nid()
    SPINNERS[i] = {'label': label, 'value': 0, 'min': 0, 'max': 100, 'step': 1}
    PROPS[i] = {'pos': (0, 0), 'size': 12, 'align': 'left', 'color': (1, 1, 1, 1)}
    VISIBLE[i] = 1
    return i

def addButton(c, text):
    assert isinstance(text, str)
    i = _nid()
    BUTTONS[i] = text
    PROPS[i] = {'pos': (0, 0), 'size': 12, 'align': 'left', 'color': (1, 1, 1, 1)}
    VISIBLE[i] = 1
    return i

def setRange(c, lo, hi):
    assert c in SPINNERS, "setRange on non-spinner"
    SPINNERS[c]['min'], SPINNERS[c]['max'] = lo, hi
    return 1

def setStep(c, v):
    assert c in SPINNERS, "setStep on non-spinner"
    SPINNERS[c]['step'] = v
    return 1

def setValue(c, v):
    assert c in SPINNERS, "setValue on non-spinner"
    lo, hi = SPINNERS[c]['min'], SPINNERS[c]['max']
    assert lo <= v <= hi, "setValue %r outside range [%r, %r]" % (v, lo, hi)
    SPINNERS[c]['value'] = v
    return 1

def getValue(c):
    assert c in SPINNERS, "getValue on non-spinner"
    return SPINNERS[c]['value']

def addOnValueChangeListener(c, fn):
    LISTENERS[('value', c)] = fn; return 1

def addOnClickedListener(c, fn):
    LISTENERS[('click', c)] = fn; return 1

def setVisible(c, v):
    assert v in (0, 1, True, False), "setVisible expects 0/1, got %r" % (v,)
    VISIBLE[c] = int(v); return 1

# --- test helpers: drive the UI the way a player would --------------------
def user_clicks(c):
    LISTENERS[('click', c)]()

def user_sets_spinner(c, v):
    lo, hi = SPINNERS[c]['min'], SPINNERS[c]['max']
    assert lo <= v <= hi
    SPINNERS[c]['value'] = v
    LISTENERS[('value', c)]()
