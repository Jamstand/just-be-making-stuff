"""
items/dryersheet.py - the DryerSheet item (ReplicatedStorage.ItemMeshes.DryerSheet, and its max-level
DryerSheet_Gold): the Dryer-Sheet Glider, a big white dryer sheet curved like a little parachute
canopy. See items/__init__.py for the conventions.

The sheet is one thin closed shell: a rounded square (corners rounded off, ~4 across) draped into a
dome whose corners droop lowest (their very tips flick up a little) and whose edges ripple softly, a
top and an underside joined by a narrow rim (so the outline hull wraps it cleanly). A light-blue
border band with a dashed stitch line runs round the top; a bold light-blue floral print (five-petal
flowers with a darker rim and a yellow heart, little leaf sprigs, dots and white "fresh" twinkles)
is scattered over the top and, paler, under it. Four light-blue cords run from near the corners down
to a cord lock on a chunky toggle ring (lying flat) under the middle; the cords get their own thin
ink hull.

DryerSheet_Gold: the same shape, skeleton and markers in polished gold (the bake paints it as metal):
white-gold flowers with sapphire hearts, a deep-gold border with white-gold stitches, twinkles and
glitter flecks, gold cords and handle with a sapphire on the cord lock.

1 unit = 1 stud: ~4.0 across, ~1.75 tall. Origin = the floor under the handle; `_Grip` = the ring
handle (the game raises it above the head, so the canopy floats over the player).

The skeleton (`rig`): `Root` at the grip (unweighted), `Canopy` (child of Root) from the grip up to
the crown: the handle, the cords' lower ends and the middle of the sheet ride it, so turning it about
its head tips the whole canopy about the hand. `Corner1`..`Corner4` (children of Canopy) lie on the
sheet from halfway out to each corner's tip: Corner1 front-left, Corner2 front-right, Corner3
back-right, Corner4 back-left as seen by the player holding it (front = model -Y, left = model +X).
The sheet is one smooth weight field over its plan (the corners take over from the canopy from ~1/3
of the way out, and neighbouring corners share the middle of each edge), so turning a corner bone
flaps that corner up / down and the sheet between ripples smoothly; each cord blends from Canopy at
the handle to its corner's weights at the sheet.
Every bone's local +Y runs head -> tail. Root, Canopy: local +Z = the front (-Y), +X = model +X.
The corners: local +Z points up out of the sheet and local +X lies level across the corner, so a
positive turn about a corner's own X lifts its tip (flaps it up), a negative one droops it, the same
way for all four. `POSES` holds preview.py's test poses.
"""
import math
import bmesh
from mathutils import Vector
import sockkit as K
from sockkit import M, hexcol
import items
from items import movekit
from props.slippers import _outward
from items.towel import _iso_cut as _iso_cut_f
from items.staticballoon import bvh_of, decal, no_bounce, offset_poly, thin_hull, tone

NAME = "DryerSheet"

MATERIALS = {"dryersheet_sheet": "fabric", "dryersheet_under": "fabric", "dryersheet_flower": "print",
             "dryersheet_leaf": "print", "dryersheet_heart": "print", "dryersheet_cord": "rope",
             "dryersheet_handle": "plastic", "dryersheet_border": "fabric", "dryersheet_twinkle": "decal",
             "dryersheet_gold": "metal", "dryersheet_gold_cord": "rope", "dryersheet_gold_flower": "print",
             "dryersheet_gold_leaf": "print", "dryersheet_gold_gem": "glass", "dryersheet_gold_shine": "decal",
             "dryersheet_gold_glitter": "decal"}


def _colours(gold=False):
    """Registers this item's palette colours and returns them. Called by build(), not at import:
    build_all.py imports every item module before it builds the socks, so colours registered at
    import would take palette cells ahead of the socks' (items must come last, see items/__init__.py)."""
    if not gold:
        return dict(
            sheet=(hexcol("dryersheet_sheet_light", "#FAFCFF"), hexcol("dryersheet_sheet", "#EDF2FA"),
                   hexcol("dryersheet_sheet_dark", "#D9E4F3")),
            under=(hexcol("dryersheet_under_light", "#F1F6FD"), hexcol("dryersheet_under", "#E2EBF7"),
                   hexcol("dryersheet_under_dark", "#C9D7EC")),
            border=(hexcol("dryersheet_border", "#B9DCF7"), hexcol("dryersheet_border_dark", "#93C2EA")),
            stitch=hexcol("dryersheet_stitch", "#5E9CDA"),
            flower=(hexcol("dryersheet_flower", "#7DBDF0"), hexcol("dryersheet_flower_pale", "#B4D8F6")),
            rim=(hexcol("dryersheet_flower_rim", "#4F94D6"), hexcol("dryersheet_flower_rim_pale", "#93C3EE")),
            heart=(hexcol("dryersheet_heart", "#FFDF7E"),) * 3,
            leaf=(hexcol("dryersheet_leaf", "#9ACDE8"), hexcol("dryersheet_leaf_pale", "#C3E0F2")),
            twinkle=hexcol("dryersheet_twinkle", "#FFFFFF"),
            cord=hexcol("dryersheet_cord", "#9CC9EE"),
            handle=(hexcol("dryersheet_handle_light", "#B9E0FF"), hexcol("dryersheet_handle", "#79B8EE"),
                    hexcol("dryersheet_handle_dark", "#4F8CCF")))
    G = movekit.gold("dryersheet")
    return dict(
        sheet=(G.light, G.base, G.dark),
        under=(hexcol("dryersheet_gold_under_light", "#F8D77E"), hexcol("dryersheet_gold_under", "#E9B54A"),
               hexcol("dryersheet_gold_under_dark", "#C98B2A")),
        border=(G.dark, G.deep), stitch=G.shine,
        flower=(hexcol("dryersheet_gold_flower", "#FFF5D2"), hexcol("dryersheet_gold_flower_pale", "#FBE3A6")),
        rim=(G.deep, G.dark),
        heart=movekit.gem_colours("dryersheet", "sapphire", "#9CD8FF", "#2F8BEA", "#1A55B0"),
        leaf=(hexcol("dryersheet_gold_leaf", "#FFE9A6"), hexcol("dryersheet_gold_leaf_pale", "#F6D88C")),
        twinkle=G.shine, glitter=G.glitter,
        cord=hexcol("dryersheet_gold_cord", "#FFD45A"),
        handle=(G.light, G.base, G.dark))


OUTLINE_W = 0.05
CORD_INK = 0.014
CORD_R = 0.022
CUTS = (-0.3, 0.75)
GOLD_CUTS = (0.42, 0.9)   # the golden sheet's top: tones by facing the key light (dark / base / lit)
HALF = 2.0                # half the sheet's side
THICK = 0.05              # sheet thickness
TOP_Z = 1.75              # the canopy's crown
DROOP = 0.44              # how far the middle of an edge sits below the crown ...
CORNER = 0.2              # ... and how much further the corners droop ...
FLICK = 0.13              # ... though their very tips flick back up this much
GRID = 24                 # grid cells across
SQ_P = 7.0                # corner rounding (superellipse exponent of the outline)
BORDER = 0.9              # the border band: from this far out (max-norm of the grid) to the edge
RING_Z, RING_R, RING_T = 0.2, 0.2, 0.065      # the ring handle (lying flat, a toggle ring): centre z, radius, tube
LOCK = (0.28, 0.22, 0.22) # the cord lock on it (size) ...
LOCK_Z = 0.37             # ... its centre
CORD_TOP = LOCK_Z + LOCK[2] * 0.5 + 0.03      # where the cords meet, on top of the lock
GRIP = Vector((0.0, 0.0, RING_Z))             # the ring (the fist)
CORD_AT = 0.72            # cords attach this far out toward each corner (sheet coordinates)
# corners in order (sheet x, y signs): front-left (+X, -Y), front-right, back-right, back-left
CORNERS = ((1, -1), (-1, -1), (-1, 1), (1, 1))


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
    """Top surface height at sheet position (x, y) in -1..1: a dome, corners drooping (their tips
    flicking up), edges rippling."""
    r2 = x * x + y * y
    z = TOP_Z - DROOP * r2 - CORNER * (x * x) * (y * y) * 1.6
    z += FLICK * (abs(x) * abs(y)) ** 6
    edge = max(abs(x), abs(y)) ** 6
    ang = math.atan2(y, x)
    z += 0.08 * edge * math.sin(8 * ang + 0.6)
    return z


def _point(x, y, lift=0.0):
    return Vector((x * HALF * (1 - 0.06 * y * y), y * HALF * (1 - 0.06 * x * x), _height(x, y) + lift))


def _sheet(P, gold):
    n = GRID
    bm = bmesh.new()
    side = bm.faces.layers.int.new("side")   # 1 = top, 0 = underside, 2 = rim
    top, bot = {}, {}
    mn = {}
    for i in range(n + 1):
        for j in range(n + 1):
            u, v = -1 + 2 * i / n, -1 + 2 * j / n
            x, y = _squircle(u, v)
            top[i, j] = bm.verts.new(_point(x, y))
            bot[i, j] = bm.verts.new(_point(x, y, -THICK))
            mn[top[i, j]] = mn[bot[i, j]] = max(abs(u), abs(v))
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
    lit = {vt: (vt.normal.dot(movekit.KEY) if vt.normal.z > 0 else 0.0) for vt in bm.verts}
    F = {"m": mn, "t": nz, "k": lit}
    _iso_cut_f(bm, F, "m", (BORDER,))    # the border band's inner edge, then the tones
    _iso_cut_f(bm, F, "t", CUTS)
    if gold:                             # polished: lit toward the key light, darker away from it
        _iso_cut_f(bm, F, "k", GOLD_CUTS)
    pal = []
    for f in bm.faces:
        t = sum(nz[v] for v in f.verts) / len(f.verts)
        m = sum(mn[v] for v in f.verts) / len(f.verts)
        if f[side] == 2:
            pal.append(P["border"][1])
        elif f[side] == 1 and m > BORDER:
            pal.append(P["border"][0] if t > CUTS[0] else P["border"][1])
        elif f[side] == 1 and gold:
            k = sum(lit[v] for v in f.verts) / len(f.verts)
            pal.append(tone(P["sheet"], k, GOLD_CUTS))
        else:
            pal.append(tone(P["sheet"], t, CUTS) if f[side] == 1 else tone(P["under"], t, CUTS))
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


def _leaf(length, width, ang, n=7):
    """A pointed leaf (CCW) from the origin out along `ang`."""
    pts = [(length * k / n, width * math.sin(math.pi * k / n)) for k in range(n + 1)]
    pts += [(length * k / n, -width * math.sin(math.pi * k / n)) for k in range(n - 1, 0, -1)]
    c, s = math.cos(ang), math.sin(ang)
    return [(x * c - y * s, x * s + y * c) for x, y in pts]


# (sheet x, y, flower radius, spin) - scattered, not on a grid (inside the border band)
FLOWERS = [(0.0, 0.02, 0.42, 0.2), (-0.52, 0.44, 0.33, 1.0), (0.5, 0.5, 0.3, 0.4), (0.52, -0.42, 0.35, 2.1),
           (-0.47, -0.48, 0.31, 0.7), (-0.8, -0.02, 0.2, 1.6), (0.8, 0.04, 0.2, 0.9), (0.04, 0.8, 0.21, 2.4),
           (0.02, -0.8, 0.21, 0.1), (-0.78, 0.76, 0.15, 0.3), (0.78, -0.76, 0.15, 1.2), (0.78, 0.76, 0.14, 2.0),
           (-0.78, -0.76, 0.15, 0.8)]
DOTS = [(-0.25, 0.55), (0.27, 0.24), (-0.3, -0.18), (0.3, -0.72), (0.72, 0.3), (-0.65, 0.22), (0.2, 0.58),
        (-0.15, -0.64), (0.66, -0.12), (-0.62, -0.25)]
TWINKLES = [(-0.25, 0.25, 0.09, 0.2), (0.3, 0.02, 0.07, 0.0), (0.24, -0.3, 0.08, 0.5), (-0.2, -0.38, 0.065, 0.3),
            (-0.66, 0.6, 0.06, 0.1), (0.64, 0.66, 0.06, 0.4), (0.62, -0.62, 0.065, 0.2), (-0.62, -0.64, 0.06, 0.0)]


def _prints(P, bvh, gold):
    out = []
    for face, cols in ((1, (P["flower"][0], P["leaf"][0], P["rim"][0])),
                       (-1, (P["flower"][1], P["leaf"][1], P["rim"][1]))):
        along = Vector((0, 0, -face))   # top: cast down; underside: cast up
        dv = Vector((0, 1, 0))
        du = Vector((face, 0, 0))       # mirrored underneath so the print reads the same through it
        lift = 0.006

        def flip(poly):
            return [(-a, b) for a, b in reversed(poly)] if face < 0 else poly
        for (x, y, r, spin) in FLOWERS:
            p = _point(x, y)
            o = Vector((p.x, p.y, 0.0))
            rot = [(a * math.cos(spin) - b * math.sin(spin), a * math.sin(spin) + b * math.cos(spin))
                   for a, b in _flower(r)]
            if r > 0.25:   # two leaves on the bigger flowers
                for la in (spin + 2.5, spin + 3.7):
                    lf = _leaf(r * 0.85, r * 0.22, la)
                    lf = [(a + math.cos(la) * r * 0.8, b + math.sin(la) * r * 0.8) for a, b in lf]
                    out.append(decal(bvh, flip(lf), o, du, dv, along, lift, cols[1], "leaf", step=0.15))
            if face > 0:   # a darker rim round the flowers on top (mostly covered: few inner points)
                out.append(decal(bvh, flip(offset_poly(rot, 0.035, miter=1.4)), o, du, dv, along, lift * 1.5, cols[2],
                                 "flower_rim", step=0.3))
            out.append(decal(bvh, flip(rot), o, du, dv, along, lift * 2.5, cols[0], "flower", step=0.11))
            heart = P["heart"]
            if gold and face > 0:   # sapphire hearts: lit upper left, shaded lower right
                hp = lambda q, n, heart=heart: heart[0] if q.x + q.y < -0.04 * r / 0.3 else heart[1]
            else:
                hp = heart[1] if gold else heart[0]
            out.append(decal(bvh, movekit.circle(r * 0.3, 12), o, du, dv, along, lift * 3.5, hp, "heart", step=0.2))
        for (x, y) in DOTS:
            p = _point(x, y)
            o = Vector((p.x, p.y, 0.0))
            out.append(decal(bvh, movekit.circle(0.06, 8), o, du, dv, along, lift, cols[0], "flower", step=0.2))
        if face > 0:
            for (x, y, r, rot) in TWINKLES:
                p = _point(x, y)
                o = Vector((p.x, p.y, 0.0))
                out.append(decal(bvh, movekit.sparkle(r, 0.26, rot=rot), o, du, dv, along, lift, P["twinkle"],
                                 "twinkle", step=0.1))
            if gold:
                for x, y in movekit.dots(26, 7.0, (-0.85, -0.85), (0.85, 0.85), 0.16):
                    p = _point(x, y)
                    out.append(decal(bvh, movekit.circle(0.022, 6), Vector((p.x, p.y, 0.0)), du, dv, along, lift,
                                     P["glitter"], "glitter", step=0.2))
    return out


def _stitches(P, bvh):
    """A dashed stitch line round the border band (on top)."""
    out = []
    n = GRID * 4 * 2
    m = (1.0 + BORDER) * 0.5 - 0.005
    ring = []
    for k in range(n):
        t = k / n * 4.0                      # walk the max-norm square ring, side by side
        sd, f = int(t), t - int(t)
        u, v = ((-m + 2 * m * f, -m), (m, -m + 2 * m * f), (m - 2 * m * f, m), (-m, m - 2 * m * f))[sd]
        ring.append(_squircle(u, v))
    for k in range(0, n, 2):
        a, b = Vector(_point(*ring[k])), Vector(_point(*ring[(k + 1) % n]))
        a.z = b.z = 0.0
        c = (a + b) * 0.5
        d = (b - a)
        L = d.length
        if L < 1e-6:
            continue
        d /= L
        w = Vector((-d.y, d.x, 0.0)) * 0.016
        poly = [tuple(-d * L * 0.36 - w)[:2], tuple(d * L * 0.36 - w)[:2], tuple(d * L * 0.36 + w)[:2],
                tuple(-d * L * 0.36 + w)[:2]]
        out.append(decal(bvh, poly, c, (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.006, P["stitch"], "stitch", step=1.0,
                         smooth=False))
    return out


def _attach(k):
    sx, sy = CORNERS[k]
    x, y = _squircle(sx * CORD_AT, sy * CORD_AT)
    return _point(x, y, -THICK - 0.005)


def _cords(P):
    out = []
    top = Vector((0, 0, CORD_TOP))
    for k in range(4):
        a = _attach(k)
        mid = a.lerp(top, 0.5) + Vector((0, 0, -0.05))
        pc = K.tube(P["cord"], [tuple(a), tuple(mid), tuple(top)], radius=CORD_R, res=6, bevel_res=0, outline=False,
                    name="cord")
        pc.rig = ("cord", k)
        out.append(pc)
    return out


def _handle(P, gold):
    """The cord lock (a chunky rounded block the cords are tied into, a knot on top) sitting on a
    ring handle lying flat (a toggle ring: never a bar or a stick from any side) the fist holds."""
    out = []
    lock = K.rounded_box(P["handle"][1], LOCK, M((0, 0, LOCK_Z)), bevel=0.07, segments=3, name="handle")
    K.recolor_by(lock, lambda c, cur: P["handle"][0] if c.z > LOCK_Z + 0.07 else
                 (P["handle"][2] if c.x > 0.08 or c.z < LOCK_Z - 0.08 else cur))
    out.append(lock)
    ring = K.torus(P["handle"][1], RING_R, RING_T, M((0, 0, RING_Z)), seg=20, mseg=8, name="handle_ring")
    K.recolor_by(ring, lambda c, cur: P["handle"][0] if c.z > RING_Z + 0.03 else
                 (P["handle"][2] if c.z < RING_Z - 0.03 else cur))
    out.append(ring)
    out.append(K.sphere(P["cord"], 0.065, M((0, 0, CORD_TOP)), seg=10, rings=6, name="cord_knot"))
    if gold:
        out.append(movekit.gem(P["heart"], (0, -LOCK[1] * 0.5 - 0.004, LOCK_Z), (0, -1, 0.05), 0.07, name="gem"))
    for pc in out:
        pc.rig = "handle"
    return out


def build(gold=False):
    name = NAME + ("_Gold" if gold else "")
    P = _colours(gold)
    sheet = _sheet(P, gold)
    bvh = bvh_of([sheet])
    p = [sheet] + _prints(P, bvh, gold) + _stitches(P, bvh) + _cords(P) + _handle(P, gold)
    body, outline = K.finish(p, name, outline_width=OUTLINE_W)
    thin_hull(outline, _cords(P), CORD_INK)
    no_bounce(outline)
    return [body, outline] + K.markers(name) + [items.grip(name, GRIP)]


BUILDERS = {NAME: build, NAME + "_Gold": lambda: build(True)}


# ---------------------------------------------------------------- skeleton
def _field(X, Y):
    """Canopy / Corner1..4 weights over the sheet's plan (model X, Y)."""
    x, y = X / HALF, Y / HALF
    c = movekit.smooth(0.3, 0.85, math.hypot(x, y))
    w = {"Canopy": 1.0 - c}
    for k, (sx, sy) in enumerate(CORNERS):
        share = movekit.smooth(-0.3, 0.3, sx * x) * movekit.smooth(-0.3, 0.3, sy * y)
        if share * c > 0.0:
            w[f"Corner{k + 1}"] = share * c
    return w


def _cord_weights(k, co):
    a = _attach(k)
    t = max(0.0, min(1.0, (co.z - CORD_TOP) / (a.z - CORD_TOP)))
    return movekit.mix({"Canopy": 1.0}, _field(a.x, a.y), t)


def rig(name, objs):
    """`<Name>_Rig`: Root at the grip, Canopy up to the crown, Corner1..4 out to the corner tips."""
    crown = Vector((0, 0, TOP_Z))
    bones = {"Root": movekit.bone("Root", None, GRIP, GRIP - Vector((0, 0, 0.3)), "root"),
             "Canopy": movekit.bone("Canopy", "Root", GRIP, crown, "canopy")}
    for k, (sx, sy) in enumerate(CORNERS):
        head = _point(*_squircle(sx * 0.48, sy * 0.48))
        tail = _point(*_squircle(sx * 0.99, sy * 0.99))
        bones[f"Corner{k + 1}"] = movekit.bone(f"Corner{k + 1}", "Canopy", head, tail, "corner")

    def weigh(piece, tag, co):
        if tag == "handle":
            return {"Canopy": 1.0}
        if isinstance(tag, tuple):
            return _cord_weights(tag[1], co)
        if piece is None:          # the cords' thin ink hull: which cord by its quadrant
            if co.z < CORD_TOP + 0.05:
                return {"Canopy": 1.0}
            k = CORNERS.index((1 if co.x > 0 else -1, 1 if co.y > 0 else -1))
            return _cord_weights(k, co)
        return _field(co.x, co.y)
    return movekit.skin(name, objs, bones, weigh, rolls={f"Corner{k + 1}": (0, 0, 1) for k in range(4)})


# test poses for preview.py --pose (rigging.apply_pose: world axes, degrees). A corner flaps about
# the horizontal axis across it: (sy, -sx, 0) turns corner (sx, sy) up for a positive angle.
def _flap(k, deg):
    sx, sy = CORNERS[k]
    return [((sy, -sx, 0), deg)]


POSES = {
    "rest": {},
    # gliding: the corners flapping (alternate pairs up / down), the canopy tipped forward a little
    "glide": {"Canopy": [((1, 0, 0), 8)], "Corner1": _flap(0, 22), "Corner2": _flap(1, -14), "Corner3": _flap(2, 22),
              "Corner4": _flap(3, -14)},
    # every corner flapped right up, then right down (the limits)
    "up": {f"Corner{k + 1}": _flap(k, 35) for k in range(4)},
    "down": {f"Corner{k + 1}": _flap(k, -30) for k in range(4)},
    # the canopy swung sideways about the hand
    "tilt": {"Canopy": [((0, 1, 0), 20)], "Corner1": _flap(0, 10), "Corner4": _flap(3, 10)},
}
