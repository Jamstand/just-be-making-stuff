"""
items/dashslippers.py - the DashSlippers item (ReplicatedStorage.ItemMeshes.DashSlippers): the Slipper
Dash's pair of speedy fuzzy slippers, tied together by a ribbon and held by its bow. See
items/__init__.py for the conventions.

Cousins of the bedroom's bunny slippers (props/slippers.py: the same plush loft idea, iso-cut tones,
a fluffy collar), but built for speed instead of cuddles: no ears or face, a chunkier, taller toe
box, a thick sneaker sole (a white midsole with a yellow racing stripe over a dark purple tread), a
yellow lightning bolt stitched onto each toe (a felt patch ringed with ink stitches) and three
little white wing feathers at each outer heel. A hot-pink ribbon loops through both collars up to a
bow above them, where the hand holds the pair.

1 unit = 1 stud: each slipper ~1.1 long, the pair ~1.3 across (with the wings), ~1.6 tall with the
bow. Origin = the floor centre under the pair; `_Grip` = the bow's knot (the fist; the toes point
forward and the slippers hang under it), `_Tip` = between the two toes (the dash trail's start).
"""
import math
import bmesh
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
import items
from props.slippers import _iso_cut, _outward, _smooth, _spow, _interp
from items.staticballoon import BOLT, bvh_of, decal, no_bounce, offset_poly, tone

NAME = "DashSlippers"

MATERIALS = {"dashslippers_plush": "fur", "dashslippers_fluff": "fluff", "dashslippers_sole": "rubber",
             "dashslippers_mid": "rubber", "dashslippers_racing": "rubber", "dashslippers_bolt": "felt",
             "dashslippers_stitch": "ink", "dashslippers_wing": "felt", "dashslippers_ribbon": "fabric",
             "dashslippers_lining": "felt"}


def _colours():
    """Registers this item's palette colours. Called by build(), not at import: build_all.py imports
    every item module before it builds the socks, so colours registered at import would take palette
    cells ahead of the socks' (items must come last, see items/__init__.py)."""
    global PLUSH, LINING, FLUFF, SOLE, MID, STRIPE, BOLT_C, STITCH, WING, RIBBON
    PLUSH = (hexcol("dashslippers_plush_light", "#E8D9FF"), hexcol("dashslippers_plush", "#C6A6FF"),
             hexcol("dashslippers_plush_dark", "#A283EC"), hexcol("dashslippers_plush_deep", "#8064D0"))
    LINING = (hexcol("dashslippers_lining", "#8B5BD6"), hexcol("dashslippers_lining_dark", "#6A41B4"))
    FLUFF = (hexcol("dashslippers_fluff_light", "#FFFFFF"), hexcol("dashslippers_fluff", "#F7F2FF"),
             hexcol("dashslippers_fluff_dark", "#D6CCEA"))
    SOLE = (hexcol("dashslippers_sole", "#5C46AE"), hexcol("dashslippers_sole_dark", "#3F2E84"))
    MID = (hexcol("dashslippers_mid_light", "#FFFFFF"), hexcol("dashslippers_mid", "#EDE8F8"))
    STRIPE = hexcol("dashslippers_racing", "#FFCF33")
    BOLT_C = (hexcol("dashslippers_bolt_light", "#FFDF3D"), hexcol("dashslippers_bolt", "#FFBE0F"))
    STITCH = hexcol("dashslippers_stitch", "#5A3A10")
    WING = (hexcol("dashslippers_wing_light", "#FFFFFF"), hexcol("dashslippers_wing", "#ECEFFA"),
            hexcol("dashslippers_wing_dark", "#C9CEE6"))
    RIBBON = (hexcol("dashslippers_ribbon_light", "#FF8CC0"), hexcol("dashslippers_ribbon", "#FF4F9A"),
              hexcol("dashslippers_ribbon_dark", "#D7337C"))


OUTLINE_W = 0.032
TONE_CUTS = (-0.5, -0.1, 0.78)
HALF_L = 0.52                    # half length of the plush body
FLOOR = 0.12                     # top of the sole (the plush body sits on it)
OPEN_C = Vector((0.0, 0.25))     # foot opening centre (x, y) ...
OPEN_A = (0.13, 0.2)             # ... and half axes
# body stations (y, half width, roof z): a tall, round toe box at -Y
STATIONS = [(-0.52, 0.17, 0.3), (-0.42, 0.23, 0.42), (-0.26, 0.25, 0.47), (-0.06, 0.245, 0.45), (0.12, 0.235, 0.4),
            (0.3, 0.225, 0.38), (0.44, 0.215, 0.38), (0.52, 0.19, 0.36)]
PAIR_X = 0.27                    # each slipper's centre line (x)
BOW = Vector((0.0, 0.2, 1.44))   # the bow's knot
TIP = Vector((0.0, -0.58, 0.2))


def _loft(q, grow=0.0, roof=None, floor=FLOOR, equator=0.22, dip=True):
    """Unit sphere point (pole on Y) -> slipper surface (slipper frame: toe -Y, floor z = 0)."""
    u, v, w = q
    e1 = 0.55
    y = _spow(v, e1) * (HALF_L + grow)
    r = math.sqrt(max(0.0, u * u + w * w))
    rr = r ** e1
    cu, cw = (u / r, w / r) if r > 1e-9 else (0.0, 0.0)
    hw = _interp(y, STATIONS, 1) + grow
    x = hw * rr * _spow(cu, 0.6)
    top = roof if roof is not None else _interp(y, STATIONS, 2)
    if w >= 0:
        z = equator + (top - equator) * rr * _spow(cw, 0.7)
    else:
        z = equator + (equator - floor) * rr * _spow(cw, 0.3)
    if dip and w > 0:   # the foot opening: a hollow in the roof at the back
        d = ((x - OPEN_C.x) / (OPEN_A[0] + 0.03)) ** 2 + ((y - OPEN_C.y) / (OPEN_A[1] + 0.03)) ** 2
        z -= 0.13 * _smooth(1.0, 0.35, d) * _smooth(0.1, 0.7, cw)
    return Vector((x, y, z))


def _sphere_map(fn, seg, rings):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
    for vt in bm.verts:
        x, y, z = vt.co
        vt.co = fn(Vector((y, z, x)))   # cyclic axis swap (keeps the winding): poles -> +-Y
    _outward(bm)
    bm.normal_update()
    return bm


def _body():
    bm = _sphere_map(_loft, 24, 15)
    nz = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, nz, TONE_CUTS)

    def oval(co):
        return ((co.x - OPEN_C.x) / OPEN_A[0]) ** 2 + ((co.y - OPEN_C.y) / OPEN_A[1]) ** 2
    d = {v: oval(v.co) for v in bm.verts}
    _iso_cut(bm, d, (1.0,))
    bm.normal_update()
    fp = []
    for f in bm.faces:
        c = f.calc_center_median()
        n = sum(v.normal.z for v in f.verts) / len(f.verts)
        if oval(c) < 1.0 and c.z > 0.2:
            fp.append(LINING[0] if n > 0.75 else LINING[1])
        else:
            fp.append(tone(PLUSH, n, TONE_CUTS))
    return K.Piece(K._bm_to_mesh(bm, "body"), fp, True, True, "body")


def _sole():
    """A thick sneaker sole: dark tread at the bottom, white midsole, a yellow stripe round it."""
    bm = _sphere_map(lambda q: _loft(q, grow=0.035, roof=FLOOR + 0.06, floor=0.0, equator=0.07, dip=False), 26, 8)
    zs = {v: v.co.z for v in bm.verts}
    _iso_cut(bm, zs, (0.035, 0.07, 0.105))
    bm.normal_update()
    fp = []
    for f in bm.faces:
        z = sum(zs[v] for v in f.verts) / len(f.verts)
        if z < 0.035:
            fp.append(SOLE[1] if f.normal.z < -0.5 else SOLE[0])
        elif 0.07 < z < 0.105:
            fp.append(STRIPE)
        else:
            fp.append(MID[0] if f.normal.z > 0.6 else MID[1])
    return K.Piece(K._bm_to_mesh(bm, "sole"), fp, True, True, "sole")


def _collar(bvh):
    """A fluffy scalloped collar round the foot opening (like the bunny slippers', a bit plumper)."""
    n_b, per = 8, 3
    pts, radii = [], []
    for i in range(n_b * per):
        t = i / (n_b * per) * math.tau
        x, y = OPEN_C.x + (OPEN_A[0] + 0.015) * math.cos(t), OPEN_C.y + (OPEN_A[1] + 0.015) * math.sin(t)
        loc = bvh.ray_cast(Vector((x, y, 3.0)), Vector((0, 0, -1)))[0]
        pts.append(loc + Vector((0, 0, 0.012)))
        radii.append(0.05 * (1 + 0.25 * math.cos(i / per * math.tau)))
    bm = bmesh.new()
    sides = 6
    rings = []
    n = len(pts)
    up = Vector((0, 0, 1))
    for i in range(n):
        tng = (pts[(i + 1) % n] - pts[i - 1]).normalized()
        nn = (up - tng * up.dot(tng)).normalized()
        b = tng.cross(nn)
        rings.append([bm.verts.new(pts[i] + (nn * math.cos(a) + b * math.sin(a)) * radii[i])
                      for a in (j / sides * math.tau for j in range(sides))])
    for i in range(n):
        a, b = rings[i], rings[(i + 1) % n]
        for j in range(sides):
            k = (j + 1) % sides
            bm.faces.new((a[j], b[j], b[k], a[k]))
    _outward(bm)
    bm.normal_update()
    fp = [tone(FLUFF, f.normal.z, (-0.2, 0.6)) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, "collar"), fp, True, True, "collar")


def _bolt(bvh, outer):
    """The stitched lightning bolt on the toe: a felt patch pointing at the toe, an ink stitch ring."""
    out = []
    o = Vector((0.0, -0.25, 2.0))
    down = Vector((0, 0, -1))
    du, dv = Vector((outer, 0, 0)), Vector((0, 1, 0))   # the bolt's point aims at the toe (-Y)
    bolt = [(x * 0.56, y * 0.5) for x, y in BOLT]
    out.append(decal(bvh, bolt, o, du, dv, down, 0.008,
                     lambda q, n: BOLT_C[0] if n.z > 0.85 else BOLT_C[1], "bolt", step=0.03))
    ring = offset_poly(bolt, 0.014, miter=1.6)
    # dashes along the ring: little ink ticks, every other short segment
    path = []
    for i in range(len(ring)):
        a, b = Vector(ring[i]), Vector(ring[(i + 1) % len(ring)])
        k = max(1, int((b - a).length / 0.024))
        for j in range(k):
            path.append(a.lerp(b, j / k))
    for i in range(0, len(path) - 1, 2):
        a, b = path[i], path[i + 1]
        d = (b - a)
        if d.length < 1e-6:
            continue
        nrm = Vector((-d.y, d.x)).normalized() * 0.006
        tick = [tuple(a - nrm), tuple(b - nrm), tuple(b + nrm), tuple(a + nrm)]
        out.append(decal(bvh, tick, o, du, dv, down, 0.009, STITCH, "stitch", step=1.0, smooth=False))
    return out


def _wing(outer):
    """Three little white feathers fanned out and back from the outer heel (Hermes' sandals)."""
    out = []
    root = Vector((outer * 0.2, 0.3, 0.27))
    for k, (ang, ln) in enumerate(((4, 0.26), (27, 0.31), (50, 0.26))):
        a = math.radians(ang)
        d = Vector((outer * 0.5, math.cos(a), math.sin(a))).normalized()   # out, back and up: wings, not ears
        c = root + d * (ln * 0.5)
        rot = d.to_track_quat("Y", "Z").to_matrix().to_4x4()
        side = Vector((1, 0, 0)) * outer
        # flatten across x (the feather's flat face looks sideways)
        m = Matrix.Translation(c) @ rot @ Matrix.Diagonal((0.032, ln * 0.5, 0.068, 1.0))
        pc = K.sphere(WING[1], 1.0, m, seg=10, rings=8, name="wing")
        K.recolor_by(pc, lambda q, cur, side=side, c=c: WING[0] if (q - c).dot(side) > 0.0 and q.z > c.z - 0.01 else
                     (WING[2] if q.z < c.z - 0.03 else WING[1]))
        out.append(pc)
    return out


def _slipper(outer):
    """One slipper in its own frame (toe -Y, floor z = 0); `outer` = which side faces away (+1: +X)."""
    body = _body()
    bvh = bvh_of([body])
    p = [body, _sole(), _collar(bvh)] + _bolt(bvh, outer) + _wing(outer)
    return p


def _catmull(pts, n):
    out = []
    k = len(pts) - 1
    for i in range(n + 1):
        u = i / n * k
        j = min(int(u), k - 1)
        t = u - j
        p0, p1, p2, p3 = (Vector(pts[min(max(m, 0), k)]) for m in (j - 1, j, j + 1, j + 2))
        out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                          + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    return out


def _band(path, width, thick, face, name, closed=False):
    """A flat ribbon along `path` (points): `width` across, `thick` through, its flat side facing
    `face` (a direction hint). Closed paths make a loop; open ones get end caps."""
    bm = bmesh.new()
    n = len(path)
    rings = []
    for i in range(n):
        if closed:
            tng = (path[(i + 1) % n] - path[i - 1]).normalized()
        else:
            tng = (path[min(i + 1, n - 1)] - path[max(i - 1, 0)]).normalized()
        nrm = (face - tng * face.dot(tng)).normalized()
        wd = tng.cross(nrm)
        c = path[i]
        hw, ht = width / 2, thick / 2
        rings.append([bm.verts.new(c + wd * a + nrm * b) for a, b in
                      ((hw, -ht), (hw, ht), (hw * 0.6, ht * 1.4), (-hw * 0.6, ht * 1.4), (-hw, ht), (-hw, -ht),
                       (-hw * 0.6, -ht * 1.4), (hw * 0.6, -ht * 1.4))])
    m = len(rings[0])
    for i in range(n if closed else n - 1):
        a, b = rings[i], rings[(i + 1) % n]
        for j in range(m):
            k = (j + 1) % m
            bm.faces.new((a[j], a[k], b[k], b[j]))
    if not closed:
        bm.faces.new(rings[0][::-1])
        bm.faces.new(rings[-1])
    _outward(bm)
    bm.normal_update()
    fp = [tone(RIBBON, f.normal.z, (-0.45, 0.55)) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, name), fp, True, True, name)


def _ribbon():
    """The ribbon: up from each slipper's collar to the knot, and the bow (two loops and a knot; the
    two strands below the knot read as the bow's tails)."""
    out = []
    face = Vector((0, -1, 0.15))
    for s in (-1, 1):
        start = Vector((s * PAIR_X, 0.3, 0.33))   # tucked into the collar at the heel
        ctrl = [start, start + Vector((-s * 0.02, 0.0, 0.25)), Vector((s * 0.12, 0.24, 0.85)),
                BOW + Vector((s * 0.03, 0.0, -0.06))]
        out.append(_band(_catmull(ctrl, 14), 0.075, 0.018, face, "ribbon"))
    for s in (-1, 1):   # the bow's loops: open teardrops, so their holes show (and their inner ink stays thin)
        pts = []
        for k in range(18):
            t = k / 18 * math.tau
            x = s * (0.13 + 0.13 * math.cos(t + math.pi))
            z = 0.11 * math.sin(t) * (0.35 + 0.65 * abs(math.cos(t / 2)))
            pts.append(BOW + Vector((x * 1.3, 0.0, z + abs(x) * 0.3)))
        out.append(_band(pts, 0.065, 0.016, face, "ribbon_loop", closed=True))
    knot = K.rounded_box(RIBBON[1], (0.085, 0.06, 0.08), M(BOW), bevel=0.025, segments=2, name="ribbon_knot")
    K.recolor_by(knot, lambda q, cur: RIBBON[0] if q.z > BOW.z + 0.02 else cur)
    out.append(knot)
    return out


def build():
    _colours()
    p = []
    for s in (-1, 1):   # left (-X) and right (+X) slippers, side by side, toes forward
        pieces = _slipper(s)
        yaw = -s * 0.06   # toes turned out a hair
        for pc in pieces:
            pc.mesh.transform(M((s * PAIR_X, 0, 0), rot=(0, 0, yaw)))
        p += pieces
    p += _ribbon()
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    no_bounce(outline)
    return [body, outline] + K.markers(NAME) + [items.grip(NAME, BOW), K.marker(NAME + "_Tip", TIP)]


BUILDERS = {NAME: build}
