"""
items/dryersheet.py - the DryerSheet item (ReplicatedStorage.ItemMeshes.DryerSheet): the Dryer-Sheet
Glider, a big white dryer sheet curved like a little parachute canopy. See items/__init__.py for the
conventions.

The sheet is one thin closed shell: a rounded square (corners rounded off, ~4 across) draped into a
dome whose corners droop lowest and whose edges ripple softly, a top and an underside joined by a
narrow rim (so the outline hull wraps it cleanly). A light-blue floral print (five-petal flowers
with a yellow heart, little leaf sprigs and dots) is scattered over the top and, paler, under it.
Four light-blue cords run from near the corners down to a chunky little toggle handle under the
middle; the cords get their own thin ink hull.

1 unit = 1 stud: ~4.0 across, ~1.6 tall. Origin = the floor under the handle; `_Grip` = the handle
(the game raises it above the head, so the canopy floats over the player).
"""
import math
import bmesh
from mathutils import Vector
import sockkit as K
from sockkit import M, hexcol
import items
from props.slippers import _iso_cut, _outward
from items.staticballoon import bvh_of, decal, no_bounce, thin_hull, tone

NAME = "DryerSheet"

MATERIALS = {"dryersheet_sheet": "fabric", "dryersheet_under": "fabric", "dryersheet_flower": "print",
             "dryersheet_leaf": "print", "dryersheet_heart": "print", "dryersheet_cord": "rope",
             "dryersheet_handle": "plastic"}


def _colours():
    """Registers this item's palette colours. Called by build(), not at import: build_all.py imports
    every item module before it builds the socks, so colours registered at import would take palette
    cells ahead of the socks' (items must come last, see items/__init__.py)."""
    global SHEET, UNDER, FLOWER, HEART, LEAF, CORD, HANDLE
    SHEET = (hexcol("dryersheet_sheet_light", "#FAFCFF"), hexcol("dryersheet_sheet", "#EDF2FA"),
             hexcol("dryersheet_sheet_dark", "#D9E4F3"))
    UNDER = (hexcol("dryersheet_under_light", "#F1F6FD"), hexcol("dryersheet_under", "#E2EBF7"),
             hexcol("dryersheet_under_dark", "#C9D7EC"))
    FLOWER = (hexcol("dryersheet_flower", "#7DBDF0"), hexcol("dryersheet_flower_pale", "#B4D8F6"))
    HEART = hexcol("dryersheet_heart", "#FFDF7E")
    LEAF = (hexcol("dryersheet_leaf", "#9ACDE8"), hexcol("dryersheet_leaf_pale", "#C3E0F2"))
    CORD = hexcol("dryersheet_cord", "#9CC9EE")
    HANDLE = (hexcol("dryersheet_handle_light", "#B9E0FF"), hexcol("dryersheet_handle", "#79B8EE"),
              hexcol("dryersheet_handle_dark", "#4F8CCF"))


OUTLINE_W = 0.05
CORD_INK = 0.014
CUTS = (-0.3, 0.75)
HALF = 2.0                # half the sheet's side
THICK = 0.035             # sheet thickness
TOP_Z = 1.6               # the canopy's crown
DROOP = 0.42              # how far the middle of an edge sits below the crown ...
CORNER = 0.2              # ... and how much further the corners droop
GRID = 24                 # grid cells across
SQ_P = 7.0                # corner rounding (superellipse exponent of the outline)
CORD_TOP = 0.36           # where the cords meet, on top of the handle
GRIP = Vector((0.0, 0.0, 0.17))
CORD_AT = 0.72            # cords attach this far out toward each corner (sheet coordinates)


def _squircle(u, v):
    """Square grid point -> the rounded-square sheet (same max-norm rings, rounded corners)."""
    m = max(abs(u), abs(v))
    if m < 1e-9:
        return 0.0, 0.0
    L = math.hypot(u, v)
    dx, dy = u / L, v / L
    R = (abs(dx) ** SQ_P + abs(dy) ** SQ_P) ** (-1.0 / SQ_P)
    return dx * m * R, dy * m * R


def _height(x, y):
    """Top surface height at sheet position (x, y) in -1..1: a dome, corners drooping, edges rippling."""
    r2 = x * x + y * y
    z = TOP_Z - DROOP * r2 / 1.0 - CORNER * (x * x) * (y * y) * 1.6
    edge = max(abs(x), abs(y)) ** 6
    ang = math.atan2(y, x)
    z += 0.07 * edge * math.sin(8 * ang + 0.6)
    return z


def _point(x, y, lift=0.0):
    return Vector((x * HALF * (1 - 0.06 * y * y), y * HALF * (1 - 0.06 * x * x), _height(x, y) + lift))


def _sheet():
    n = GRID
    bm = bmesh.new()
    side = bm.faces.layers.int.new("side")   # 1 = top, 0 = underside, 2 = rim
    top, bot = {}, {}
    for i in range(n + 1):
        for j in range(n + 1):
            u, v = -1 + 2 * i / n, -1 + 2 * j / n
            x, y = _squircle(u, v)
            top[i, j] = bm.verts.new(_point(x, y))
            bot[i, j] = bm.verts.new(_point(x, y, -THICK))
    for i in range(n):
        for j in range(n):
            f = bm.faces.new((top[i, j], top[i + 1, j], top[i + 1, j + 1], top[i, j + 1]))
            f[side] = 1
            g = bm.faces.new((bot[i, j], bot[i, j + 1], bot[i + 1, j + 1], bot[i + 1, j]))
            g[side] = 0
    ring = [(i, 0) for i in range(n)] + [(n, j) for j in range(n)] + [(i, n) for i in range(n, 0, -1)] \
        + [(0, j) for j in range(n, 0, -1)]
    for k in range(len(ring)):
        a, b = ring[k], ring[(k + 1) % len(ring)]
        f = bm.faces.new((top[a], bot[a], bot[b], top[b]))
        f[side] = 2
    _outward(bm)
    bm.normal_update()
    nz = {}
    for vt in bm.verts:   # the underside tones follow the top's (light reaches through the thin sheet)
        nz[vt] = vt.normal.z if vt.normal.z > 0 else -vt.normal.z * 0.3 - 0.2
    _iso_cut(bm, nz, CUTS)
    pal = []
    for f in bm.faces:
        t = sum(nz[v] for v in f.verts) / len(f.verts)
        pal.append(tone(SHEET, t, CUTS) if f[side] != 0 else tone(UNDER, t, CUTS))
    return K.Piece(K._bm_to_mesh(bm, "sheet"), pal, True, True, "sheet")


def _flower(r, petals=5):
    """A five-petal flower outline (CCW) of radius r."""
    pts = []
    n = petals * 8
    for k in range(n):
        a = k / n * math.tau
        rr = r * (0.55 + 0.45 * abs(math.cos(petals * a / 2)) ** 0.7)
        pts.append((rr * math.cos(a), rr * math.sin(a)))
    return pts


def _circle(r, n=10, cx=0.0, cy=0.0):
    return [(cx + r * math.cos(a), cy + r * math.sin(a)) for a in (k / n * math.tau for k in range(n))]


def _leaf(length, width, ang, n=7):
    """A pointed leaf (CCW) from the origin out along `ang`."""
    pts = [(length * k / n, width * math.sin(math.pi * k / n)) for k in range(n + 1)]
    pts += [(length * k / n, -width * math.sin(math.pi * k / n)) for k in range(n - 1, 0, -1)]
    c, s = math.cos(ang), math.sin(ang)
    return [(x * c - y * s, x * s + y * c) for x, y in pts]


# (sheet x, y, flower radius, spin) - scattered, not on a grid
FLOWERS = [(0.0, 0.02, 0.36, 0.2), (-0.55, 0.45, 0.3, 1.0), (0.52, 0.52, 0.27, 0.4), (0.55, -0.42, 0.32, 2.1),
           (-0.48, -0.5, 0.28, 0.7), (-0.86, -0.02, 0.2, 1.6), (0.88, 0.06, 0.2, 0.9), (0.04, 0.84, 0.22, 2.4),
           (0.02, -0.86, 0.22, 0.1), (-0.84, 0.84, 0.15, 0.3), (0.84, -0.84, 0.15, 1.2), (0.84, 0.84, 0.14, 2.0),
           (-0.84, -0.84, 0.15, 0.8)]
DOTS = [(-0.25, 0.55), (0.27, 0.22), (-0.28, -0.2), (0.3, -0.7), (0.72, 0.3), (-0.65, 0.22), (0.2, 0.55),
        (-0.15, -0.62), (0.65, -0.12), (-0.62, -0.25)]


def _prints(bvh):
    out = []
    for face, cols in ((1, (FLOWER[0], LEAF[0])), (-1, (FLOWER[1], LEAF[1]))):
        along = Vector((0, 0, -face))   # top: cast down; underside: cast up
        dv = Vector((0, 1, 0))
        du = Vector((face, 0, 0))       # mirrored underneath so the print reads the same through it
        lift = 0.006
        for (x, y, r, spin) in FLOWERS:
            p = _point(x, y)
            o = Vector((p.x, p.y, 0.0))
            rot = [(a * math.cos(spin) - b * math.sin(spin), a * math.sin(spin) + b * math.cos(spin))
                   for a, b in _flower(r)]
            if face < 0:
                rot = [(-a, b) for a, b in reversed(rot)]
            out.append(decal(bvh, rot, o, du, dv, along, lift, cols[0], "flower", step=0.11))
            out.append(decal(bvh, _circle(r * 0.3), o, du, dv, along, lift * 2, HEART, "heart", step=0.2))
            if r > 0.25:   # two leaves on the bigger flowers
                for la in (spin + 2.5, spin + 3.7):
                    lf = _leaf(r * 0.85, r * 0.22, la)
                    lf = [(a + math.cos(la) * r * 0.8, b + math.sin(la) * r * 0.8) for a, b in lf]
                    if face < 0:
                        lf = [(-a, b) for a, b in reversed(lf)]
                    out.append(decal(bvh, lf, o, du, dv, along, lift, cols[1], "leaf", step=0.15))
        for (x, y) in DOTS:
            p = _point(x, y)
            o = Vector((p.x, p.y, 0.0))
            out.append(decal(bvh, _circle(0.055, 8), o, du, dv, along, lift, cols[0], "flower", step=0.2))
    return out


def _cords():
    out = []
    top = Vector((0, 0, CORD_TOP))
    for sx in (-1, 1):
        for sy in (-1, 1):
            x, y = _squircle(sx * CORD_AT, sy * CORD_AT)
            a = _point(x, y, -THICK - 0.005)
            mid = a.lerp(top, 0.5) + Vector((0, 0, -0.04))
            out.append(K.tube(CORD, [tuple(a), tuple(mid), tuple(top)], radius=0.018, res=6, bevel_res=0, outline=False,
                              name="cord"))
    return out


def _handle():
    """A chunky toggle the cords are tied to: a rounded barrel with a band and a knot on top."""
    out = []
    out.append(K.rounded_box(HANDLE[1], (0.2, 0.2, 0.34), M((0, 0, 0.17)), bevel=0.09, segments=3, name="handle"))
    K.recolor_by(out[-1], lambda c, cur: HANDLE[0] if c.z > 0.31 else (HANDLE[2] if c.x > 0.07 else cur))
    out.append(K.torus(HANDLE[2], 0.105, 0.025, M((0, 0, 0.1)), seg=16, mseg=6, name="handle_band"))
    out.append(K.sphere(CORD, 0.055, M((0, 0, CORD_TOP)), seg=10, rings=6, name="cord_knot"))
    return out


def build():
    _colours()
    sheet = _sheet()
    bvh = bvh_of([sheet])
    p = [sheet] + _prints(bvh) + _cords() + _handle()
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    thin_hull(outline, _cords(), CORD_INK)
    no_bounce(outline)
    return [body, outline] + K.markers(NAME) + [items.grip(NAME, GRIP)]


BUILDERS = {NAME: build}
