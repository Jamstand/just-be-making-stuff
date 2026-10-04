"""
items/dashslippers.py - the DashSlippers item (ReplicatedStorage.ItemMeshes.DashSlippers, and its
max-level DashSlippers_Gold): the Slipper Dash's pair of speedy fuzzy slippers, tied together by a
ribbon and held by its bow. See items/__init__.py for the conventions.

Cousins of the bedroom's bunny slippers (props/slippers.py: the same plush loft idea, iso-cut tones,
a fluffy collar), but built for speed instead of cuddles: no ears or face, a big round toe box, a
thick sneaker sole (a white midsole with a yellow racing stripe over a dark purple tread with lighter
grip bars underneath, a stitch line along the seam), a yellow lightning bolt stitched onto each
toe (a felt patch with a lit facet, ringed with ink stitches), three yellow speed streaks on each
outer side and three chunky white wing feathers (each with a painted quill) at each outer heel. A
hot-pink satin ribbon (lighter edges) curls up from each heel collar, with a half twist, to a big bow
above them, where the hand holds the pair.

DashSlippers_Gold: the same shape, skeleton and markers in polished gold (the bake paints it as
metal): gold plush with a purple velvet lining, a cream fluff collar, a pearl midsole with a purple
racing stripe, faceted amethyst bolts, white-gold wings with a gem at each root, white-gold streaks
and twinkles, amethyst studs along the stripe and a gold ribbon with a big amethyst in the bow.

1 unit = 1 stud: each slipper ~1.25 long, the pair ~1.5 across (with the wings), ~1.5 tall with the
bow. Origin = the floor centre under the pair; `_Grip` = the bow's knot (the fist; the toes point
forward and the slippers hang under it), `_Tip` = between the two toes (the dash trail's start).

The skeleton (`rig`): `Root` at the bow's knot (unweighted, pointing up), `Ribbon` (child of Root:
the bow, the knot and the tops of both ribbon strands; from the knot pointing down), `SlipperL` /
`SlipperR` (children of Ribbon; from the top of their strand at the knot down to the slipper: the
strand and the whole slipper ride it rigidly, so turning it about its head swings the slipper on its
ribbon like a pendulum) and `WingL` / `WingR` (children of their slipper: the three heel feathers,
rigid; the bone lies along the wing's hinge at the heel). L = the slipper on model +X: the left one
as seen by the player holding the pair (the toes point away from them). The bones from the knot point
down: their local +Z is the front (-Y), so a turn about local +X swings the slippers forward / back
and one about local +Z swings them sideways. WingL points back along the heel and WingR forward, so
the same turn about each wing's own Y flaps both wings alike: + tips the feathers out and down, -
up and in. `POSES` holds preview.py's test poses.
"""
import math
import bmesh
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
import items
from items import movekit
from props.slippers import _iso_cut, _outward, _smooth, _spow, _interp
from items.staticballoon import BOLT, BOLT_LIT, BOLT_SHADE, bvh_of, decal, no_bounce, offset_poly, tone

NAME = "DashSlippers"

MATERIALS = {"dashslippers_plush": "fur", "dashslippers_fluff": "fluff", "dashslippers_sole": "rubber",
             "dashslippers_mid": "rubber", "dashslippers_racing": "rubber", "dashslippers_bolt": "felt",
             "dashslippers_stitch": "ink", "dashslippers_wing": "felt", "dashslippers_ribbon": "fabric",
             "dashslippers_lining": "felt", "dashslippers_speed": "felt", "dashslippers_tread": "rubber",
             "dashslippers_quill": "felt",
             "dashslippers_gold": "metal", "dashslippers_gold_lining": "fabric", "dashslippers_gold_fluff": "fluff",
             "dashslippers_gold_mid": "plastic", "dashslippers_gold_racing": "plastic",
             "dashslippers_gold_gem": "glass", "dashslippers_gold_shine": "decal", "dashslippers_gold_glitter": "decal"}


def _colours(gold=False):
    """Registers this item's palette colours and returns them. Called by build(), not at import:
    build_all.py imports every item module before it builds the socks, so colours registered at
    import would take palette cells ahead of the socks' (items must come last, see items/__init__.py)."""
    P = dict(
        plush=(hexcol("dashslippers_plush_light", "#E8D9FF"), hexcol("dashslippers_plush", "#C6A6FF"),
               hexcol("dashslippers_plush_dark", "#A283EC"), hexcol("dashslippers_plush_deep", "#8064D0")),
        lining=(hexcol("dashslippers_lining", "#8B5BD6"), hexcol("dashslippers_lining_dark", "#6A41B4")),
        fluff=(hexcol("dashslippers_fluff_light", "#FFFFFF"), hexcol("dashslippers_fluff", "#F7F2FF"),
               hexcol("dashslippers_fluff_dark", "#D6CCEA")),
        sole=(hexcol("dashslippers_sole", "#5C46AE"), hexcol("dashslippers_sole_dark", "#3F2E84")),
        tread=hexcol("dashslippers_tread", "#7A64CC"),
        mid=(hexcol("dashslippers_mid_light", "#FFFFFF"), hexcol("dashslippers_mid", "#EDE8F8")),
        stripe=hexcol("dashslippers_racing", "#FFCF33"),
        bolt=(hexcol("dashslippers_bolt_light", "#FFDF3D"), hexcol("dashslippers_bolt", "#FFBE0F"),
              hexcol("dashslippers_bolt_dark", "#F29A0C")),
        stitch=hexcol("dashslippers_stitch", "#5A3A10"),
        seam=hexcol("dashslippers_seam_stitch", "#6A4FB8"),
        speed=hexcol("dashslippers_speed", "#FFD84A"),
        wing=(hexcol("dashslippers_wing_light", "#FFFFFF"), hexcol("dashslippers_wing", "#ECEFFA"),
              hexcol("dashslippers_wing_dark", "#C9CEE6")),
        quill=hexcol("dashslippers_quill", "#B8BEDC"),
        ribbon=(hexcol("dashslippers_ribbon_light", "#FF8CC0"), hexcol("dashslippers_ribbon", "#FF4F9A"),
                hexcol("dashslippers_ribbon_dark", "#D7337C")),
        edge=hexcol("dashslippers_ribbon_edge", "#FFC2DD"))
    if gold:
        G = movekit.gold("dashslippers")
        P.update(
            plush=(G.light, G.base, G.dark, G.deep),
            lining=(hexcol("dashslippers_gold_lining", "#7A3FC8"), hexcol("dashslippers_gold_lining_dark", "#55248F")),
            fluff=(hexcol("dashslippers_gold_fluff_light", "#FFFDF4"), hexcol("dashslippers_gold_fluff", "#FFF4D6"),
                   hexcol("dashslippers_gold_fluff_dark", "#EAD6A4")),
            sole=(G.dark, G.deep), tread=G.base,
            mid=(hexcol("dashslippers_gold_mid_light", "#FFFDF6"), hexcol("dashslippers_gold_mid", "#F8EFDC")),
            stripe=hexcol("dashslippers_gold_racing", "#9452F0"),
            bolt=movekit.gem_colours("dashslippers", "amethyst", "#E3C2FF", "#A35BFF", "#6A2CC4"),
            stitch=hexcol("dashslippers_gold_stitch", "#7A4A0C"),
            seam=hexcol("dashslippers_gold_seam_stitch", "#8A5A12"),
            speed=G.shine,
            wing=(hexcol("dashslippers_gold_wing_light", "#FFFEF6"), hexcol("dashslippers_gold_wing", "#FFF1C2"),
                  hexcol("dashslippers_gold_wing_dark", "#EBCB7E")),
            quill=G.dark,
            ribbon=(G.light, G.base, G.dark), edge=G.shine, glitter=G.glitter, shine=G.shine)
    return P


OUTLINE_W = 0.032
TONE_CUTS = (-0.5, -0.1, 0.78)
HALF_L = 0.6                     # half length of the plush body
FLOOR = 0.15                     # top of the sole (the plush body sits on it)
SOLE_TOP = FLOOR + 0.07          # the sole's rim rises this high round the plush
OPEN_C = Vector((0.0, 0.29))     # foot opening centre (x, y) ...
OPEN_A = (0.15, 0.225)           # ... and half axes
# body stations (y, half width, roof z): a tall, round toe box at -Y
STATIONS = [(-0.6, 0.19, 0.34), (-0.48, 0.265, 0.5), (-0.3, 0.285, 0.555), (-0.07, 0.28, 0.525), (0.14, 0.27, 0.47),
            (0.34, 0.258, 0.445), (0.5, 0.245, 0.445), (0.6, 0.215, 0.42)]
EQUATOR = 0.255
PAIR_X = 0.3                     # each slipper's centre line (x)
YAW = 0.06                       # toes turned out a hair
BOW = Vector((0.0, 0.24, 1.25))  # the bow's knot
TIP = Vector((0.0, -0.68, 0.22))
BOW_TILT = Matrix.Rotation(math.radians(-22), 3, "X")   # the bow's loops lean back a little (round from the side too)
WING_ROOT = Vector((0.235, 0.33, 0.31))    # the wing's root on the +X slipper's outer heel (slipper frame)
FEATHERS = ((6, 0.33), (30, 0.41), (54, 0.33))   # (angle up from the back, length)


def _loft(q, grow=0.0, roof=None, floor=FLOOR, equator=EQUATOR, dip=True):
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
        z -= 0.14 * _smooth(1.0, 0.35, d) * _smooth(0.1, 0.7, cw)
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


def _body(P):
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
        if oval(c) < 1.0 and c.z > 0.22:
            fp.append(P["lining"][0] if n > 0.75 else P["lining"][1])
        else:
            fp.append(tone(P["plush"], n, TONE_CUTS))
    return K.Piece(K._bm_to_mesh(bm, "body"), fp, True, True, "body")


def _sole(P):
    """A thick sneaker sole: dark tread at the bottom, white midsole, a yellow stripe round it."""
    bm = _sphere_map(lambda q: _loft(q, grow=0.04, roof=SOLE_TOP, floor=0.0, equator=0.085, dip=False), 22, 8)
    zs = {v: v.co.z for v in bm.verts}
    _iso_cut(bm, zs, (0.045, 0.09, 0.135))
    bm.normal_update()
    fp = []
    for f in bm.faces:
        z = sum(zs[v] for v in f.verts) / len(f.verts)
        if z < 0.045:
            fp.append(P["sole"][1] if f.normal.z < -0.5 else P["sole"][0])
        elif 0.09 < z < 0.135:
            fp.append(P["stripe"])
        else:
            fp.append(P["mid"][0] if f.normal.z > 0.6 else P["mid"][1])
    return K.Piece(K._bm_to_mesh(bm, "sole"), fp, True, True, "sole")


def _collar(P, bvh):
    """A fluffy scalloped collar round the foot opening (like the bunny slippers', plumper)."""
    n_b, per = 8, 3
    pts, radii = [], []
    for i in range(n_b * per):
        t = i / (n_b * per) * math.tau
        x, y = OPEN_C.x + (OPEN_A[0] + 0.015) * math.cos(t), OPEN_C.y + (OPEN_A[1] + 0.015) * math.sin(t)
        loc = bvh.ray_cast(Vector((x, y, 3.0)), Vector((0, 0, -1)))[0]
        pts.append(loc + Vector((0, 0, 0.014)))
        radii.append(0.058 * (1 + 0.25 * math.cos(i / per * math.tau)))
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
    fp = [tone(P["fluff"], f.normal.z, (-0.2, 0.6)) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, "collar"), fp, True, True, "collar")


def _dashes(ring, length=0.024, width=0.006):
    """Little ink ticks (2D quads) along a closed 2D ring, every other short segment."""
    path = []
    for i in range(len(ring)):
        a, b = Vector(ring[i]), Vector(ring[(i + 1) % len(ring)])
        k = max(1, int((b - a).length / length))
        for j in range(k):
            path.append(a.lerp(b, j / k))
    out = []
    for i in range(0, len(path) - 1, 2):
        a, b = path[i], path[i + 1]
        d = (b - a)
        if d.length < 1e-6:
            continue
        nrm = Vector((-d.y, d.x)).normalized() * width
        out.append([tuple(a - nrm), tuple(b - nrm), tuple(b + nrm), tuple(a + nrm)])
    return out


def _bolt(P, bvh, outer, gold):
    """The stitched lightning bolt on the toe: a felt patch pointing at the toe with a lit facet (a
    faceted gem on the golden pair), an ink stitch ring."""
    out = []
    o = Vector((0.0, -0.29, 2.0))
    down = Vector((0, 0, -1))
    du, dv = Vector((outer, 0, 0)), Vector((0, 1, 0))   # the bolt's point aims at the toe (-Y)
    sx, sy = 0.66, 0.6
    bolt = [(x * sx, y * sy) for x, y in BOLT]
    out.append(decal(bvh, bolt, o, du, dv, down, 0.008, P["bolt"][1], "bolt", step=0.03))
    facets = ((BOLT_LIT, P["bolt"][0]), (BOLT_SHADE, P["bolt"][2])) if gold else ((BOLT_LIT, P["bolt"][0]),)
    for facet, col in facets:
        f = offset_poly([(x * sx, y * sy) for x, y in facet], -0.012, miter=1.6)
        out.append(decal(bvh, f, o, du, dv, down, 0.011, col, "bolt", step=0.03))
    ring = offset_poly(bolt, 0.016, miter=1.6)
    for tick in _dashes(ring):
        out.append(decal(bvh, tick, o, du, dv, down, 0.009, P["stitch"], "stitch", step=1.0, smooth=False))
    return out


def _streak(xf, xb, y, r, n=6):
    """A 2D speed streak (CCW): round at the front (xf), tapering to a thin round tail at xb > xf."""
    rt = r * 0.35
    pts = [(xb + rt * math.cos(a), y + rt * math.sin(a)) for a in (-math.pi / 2 + math.pi * k / 3 for k in range(4))]
    pts += [(xf + r * math.cos(a), y + r * math.sin(a)) for a in (math.pi / 2 + math.pi * k / n for k in range(n + 1))]
    return pts


def _side_art(P, bvh, outer, gold):
    """On the outer side: three speed streaks trailing back from mid-side (gold: white-gold, with a
    twinkle); round the seam above the sole a stitch line; under the sole lighter grip bars."""
    out = []
    side = Vector((outer, 0, 0))
    du, dv = Vector((0, -outer, 0)), Vector((0, 0, 1))      # 2D x = toward the toe (seen from outside)
    o = Vector((outer * 2.0, 0.0, 0.0))
    for xf, xb, z, r in ((-0.2, 0.12, 0.4, 0.03), (-0.28, 0.2, 0.32, 0.036), (-0.18, 0.1, 0.24, 0.028)):
        out.append(decal(bvh, _streak(xf, xb, z, r), o, du, dv, -side, 0.007, P["speed"], "speed", step=0.04))
    if gold:
        tw = movekit.sparkle(0.05, 0.25, 0.15, 0.36)
        out.append(decal(bvh, tw, o, du, dv, -side, 0.009, P["shine"], "shine", step=0.05))
    # the seam stitches: ticks on a ring just above the sole, cast inward from all round
    n = 44
    for i in range(n):
        if i % 2:
            continue
        t = i / n * math.tau
        y = math.sin(t) * (HALF_L - 0.02)
        x = math.cos(t)
        hw = _interp(y, STATIONS, 1)
        p = Vector((x * (hw + 0.4), y, SOLE_TOP + 0.035))
        inward = Vector((-x, -0.15 * math.sin(t), 0.0)).normalized()
        tng = Vector((-math.sin(t) * hw, math.cos(t) * HALF_L, 0.0)).normalized()
        hit = bvh.ray_cast(p, inward)[0]
        if hit is None:
            continue
        nrm = -inward
        a = hit - tng * 0.018
        b = hit + tng * 0.018
        w = Vector((0, 0, 0.0065))
        bm = bmesh.new()
        vs = [bm.verts.new(q + nrm * 0.006) for q in (a - w, b - w, b + w, a + w)]
        f = bm.faces.new(vs)
        bm.normal_update()
        if f.normal.dot(nrm) < 0:
            f.normal_flip()
        out.append(K.Piece(K._bm_to_mesh(bm, "seam"), P["seam"], False, False, "seam"))
    return out


def _tread(P):
    """Lighter grip bars across the bottom of the sole (seen when the slippers swing up)."""
    out = []
    for y in (-0.42, -0.24, -0.06, 0.12, 0.3, 0.46):
        hw = _interp(y, STATIONS, 1) * 0.72
        bm = bmesh.new()
        vs = [bm.verts.new((x, y + dy, -0.004)) for x, dy in ((-hw, -0.035), (hw, -0.035), (hw, 0.035), (-hw, 0.035))]
        f = bm.faces.new(vs)
        bm.normal_update()
        if f.normal.z > 0:
            f.normal_flip()
        out.append(K.Piece(K._bm_to_mesh(bm, "tread"), P["tread"], False, False, "tread"))
    return out


def _wing(P, outer, gold):
    """Three chunky feathers fanned out and back from the outer heel (Hermes' sandals), each with a
    painted quill down its middle."""
    out = []
    root = Vector((outer * WING_ROOT.x, WING_ROOT.y, WING_ROOT.z))
    for ang, ln in FEATHERS:
        a = math.radians(ang)
        d = Vector((outer * 0.4, math.cos(a), math.sin(a))).normalized()   # out, back and up: wings, not ears
        c = root + d * (ln * 0.5)
        rot = d.to_track_quat("Y", "Z").to_matrix().to_4x4()
        side = Vector((1, 0, 0)) * outer
        m = Matrix.Translation(c) @ rot @ Matrix.Diagonal((0.045, ln * 0.5, 0.1, 1.0))
        pc = K.sphere(P["wing"][1], 1.0, m, seg=10, rings=7, name="wing")
        inv = m.inverted()

        def col(q, cur, side=side, c=c, inv=inv):
            lq = inv @ q
            if abs(lq.z) < 0.17 and lq.y > -0.75 and abs(lq.x) > 0.5:   # the quill, on both flat faces
                return P["quill"]
            if (q - c).dot(side) > 0.0 and q.z > c.z - 0.01:
                return P["wing"][0]
            return P["wing"][2] if q.z < c.z - 0.03 else P["wing"][1]
        K.recolor_by(pc, col)
        out.append(pc)
    if gold:
        out.append(movekit.gem(P["bolt"], root + Vector((outer * 0.035, -0.01, 0.005)), (outer, -0.35, 0.3), 0.045,
                               name="gem"))
    return out


def _studs(P, outer):
    """Gold only: three little amethyst studs along the outer racing stripe."""
    out = []
    for y in (-0.3, -0.05, 0.2):
        hw = _interp(y, STATIONS, 1) + 0.04
        out.append(movekit.gem(P["bolt"], (outer * (hw + 0.003), y, 0.112), (outer, 0, 0), 0.03, n=6, name="gem"))
    return out


def _glints(P, bvh, outer):
    """Gold only: a polished highlight streak and a twinkle on the toe box, glitter flecks on the plush."""
    out = []
    down = Vector((0, 0, -1))
    o = Vector((0.0, 0.0, 2.0))
    du, dv = Vector((outer, 0, 0)), Vector((0, 1, 0))
    streak = _streak(-0.1, 0.1, 0.0, 0.03)
    rot = [(-0.13 + x * 0.6 - y * 0.8, -0.38 + x * 0.8 + y * 0.6) for x, y in streak]
    out.append(decal(bvh, rot, o, du, dv, down, 0.007, P["shine"], "shine", step=0.04))
    out.append(decal(bvh, movekit.sparkle(0.05, 0.25, 0.12, -0.46), o, du, dv, down, 0.009, P["shine"], "shine",
                     step=0.05))
    for x, y in movekit.dots(9, 3.0 + outer, (-0.2, -0.15), (0.2, 0.42), 0.11):
        if ((x - OPEN_C.x) / (OPEN_A[0] + 0.08)) ** 2 + ((y - OPEN_C.y) / (OPEN_A[1] + 0.08)) ** 2 < 1.0:
            continue
        out.append(decal(bvh, movekit.circle(0.013, 6, x, y), o, du, dv, down, 0.007, P["glitter"], "glitter",
                         step=0.05))
    return out


def _slipper(P, outer, gold):
    """One slipper in its own frame (toe -Y, floor z = 0); `outer` = which side faces away (+1: +X).
    -> (slipper pieces, wing pieces)."""
    body = _body(P)
    sole = _sole(P)
    bvh = bvh_of([body])
    bvh2 = bvh_of([body, sole])
    p = [body, sole, _collar(P, bvh)] + _bolt(P, bvh, outer, gold) + _side_art(P, bvh2, outer, gold) + _tread(P)
    if gold:
        p += _studs(P, outer) + _glints(P, bvh, outer)
    return p, _wing(P, outer, gold)


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


def _band(P, path, width, thick, face, name, closed=False, twist=0.0):
    """A flat satin ribbon along `path` (points): `width` across, `thick` through, its flat side facing
    `face` (a direction hint), turned up to `twist` radians about the path along its length (open
    paths: a half twist peaking in the middle). Lighter edges along both sides. Closed paths make a
    loop; open ones get end caps."""
    bm = bmesh.new()
    n = len(path)
    rings = []
    hw, ht = width / 2, thick / 2
    prof = ((hw, -ht), (hw, ht), (hw * 0.62, ht * 1.35), (-hw * 0.62, ht * 1.35), (-hw, ht), (-hw, -ht),
            (-hw * 0.62, -ht * 1.35), (hw * 0.62, -ht * 1.35))
    for i in range(n):
        if closed:
            tng = (path[(i + 1) % n] - path[i - 1]).normalized()
        else:
            tng = (path[min(i + 1, n - 1)] - path[max(i - 1, 0)]).normalized()
        nrm = (face - tng * face.dot(tng)).normalized()
        if twist and not closed:
            nrm = Matrix.Rotation(twist * math.sin(math.pi * i / (n - 1)), 3, tng) @ nrm
        wd = tng.cross(nrm)
        c = path[i]
        rings.append([bm.verts.new(c + wd * a + nrm * b) for a, b in prof])
    m = len(rings[0])
    edge_faces = set()
    for i in range(n if closed else n - 1):
        a, b = rings[i], rings[(i + 1) % n]
        for j in range(m):
            k = (j + 1) % m
            f = bm.faces.new((a[j], a[k], b[k], b[j]))
            if j != 2 and j != 6:        # everything but the two broad middle faces: the light edges
                edge_faces.add(f)
    if not closed:
        bm.faces.new(rings[0][::-1])
        bm.faces.new(rings[-1])
    _outward(bm)
    bm.normal_update()
    fp = [P["edge"] if f in edge_faces else tone(P["ribbon"], f.normal.z, (-0.45, 0.55)) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, name), fp, True, True, name)


def _strand_path(s):
    """One ribbon strand: from the slipper's heel collar (x = s * PAIR_X) up to the knot, a gentle S."""
    start = Vector((s * PAIR_X, 0.33, 0.38))   # tucked into the collar at the heel
    ctrl = [start, start + Vector((-s * 0.02, 0.06, 0.2)), Vector((s * 0.22, 0.14, 0.72)),
            Vector((s * 0.11, 0.36, 0.98)), BOW + Vector((s * 0.035, 0.0, -0.07))]
    return _catmull(ctrl, 20)


def _ribbon(P, gold):
    """The ribbon: up from each slipper's collar to the knot (a half twist each: a curling ribbon),
    and the bow (two loops and a knot; the two strands below the knot read as the bow's tails)."""
    out = []
    face = Vector((0, -1, 0.15))
    for s in (-1, 1):
        pc = _band(P, _strand_path(s), 0.12, 0.022, face, "ribbon", twist=s * 1.3)
        pc.rig = ("strand", s)
        out.append(pc)
    for s in (-1, 1):   # the bow's loops: open teardrops, so their holes show (and their inner ink stays thin)
        pts = []
        for k in range(18):
            t = k / 18 * math.tau
            x = s * (0.15 + 0.15 * math.cos(t + math.pi))
            z = 0.13 * math.sin(t) * (0.35 + 0.65 * abs(math.cos(t / 2)))
            q = Vector((x * 1.3, 0.0, z + abs(x) * 0.32))
            pts.append(BOW + BOW_TILT @ q)
        pc = _band(P, pts, 0.115, 0.022, BOW_TILT @ face, "ribbon_loop", closed=True)
        pc.rig = "bow"
        out.append(pc)
    knot = K.rounded_box(P["ribbon"][1], (0.13, 0.09, 0.125), M(BOW), bevel=0.04, segments=2, name="ribbon_knot")
    K.recolor_by(knot, lambda q, cur: P["ribbon"][0] if q.z > BOW.z + 0.025 else cur)
    knot.rig = "bow"
    out.append(knot)
    if gold:
        g = movekit.gem(P["bolt"], BOW + Vector((0, -0.043, 0.0)), (0, -1, 0.1), 0.055, name="gem")
        g.rig = "bow"
        out.append(g)
    return out


def _place(outer):
    """The slipper's frame -> model: side by side, toes forward, turned out a hair."""
    return M((outer * PAIR_X, 0, 0), rot=(0, 0, -outer * YAW))


def build(gold=False):
    name = NAME + ("_Gold" if gold else "")
    P = _colours(gold)
    p = []
    for s in (-1, 1):   # the right (-X) and left (+X) slippers, side by side, toes forward
        pieces, wing = _slipper(P, s, gold)
        for pc in pieces:
            pc.mesh.transform(_place(s))
            pc.rig = ("slipper", s)
        for pc in wing:
            pc.mesh.transform(_place(s))
            pc.rig = ("wing", s)
        p += pieces + wing
    p += _ribbon(P, gold)
    body, outline = K.finish(p, name, outline_width=OUTLINE_W)
    no_bounce(outline)
    return [body, outline] + K.markers(name) + [items.grip(name, BOW), K.marker(name + "_Tip", TIP)]


BUILDERS = {NAME: build, NAME + "_Gold": lambda: build(True)}


# ---------------------------------------------------------------- skeleton
def _side(s):
    return "L" if s > 0 else "R"


def rig(name, objs):
    """`<Name>_Rig`: Root at the knot, Ribbon (the bow), SlipperL / SlipperR (children of Ribbon),
    WingL / WingR (children of their slipper)."""
    bones = {"Root": movekit.bone("Root", None, BOW, BOW + Vector((0, 0, 0.3)), "root"),
             "Ribbon": movekit.bone("Ribbon", "Root", BOW, BOW - Vector((0, 0, 0.3)), "ribbon")}
    for s in (-1, 1):
        S = _side(s)
        top = BOW + Vector((s * 0.035, 0.0, -0.07))
        mid = _place(s) @ Vector((0.0, 0.05, 0.36))
        bones["Slipper" + S] = movekit.bone("Slipper" + S, "Ribbon", top, mid, "slipper")
        root = _place(s) @ Vector((s * WING_ROOT.x, WING_ROOT.y, WING_ROOT.z))
        hinge = (_place(s).to_3x3() @ Vector((0, 1, 0))) * (0.2 * s)    # L: back, R: forward
        bones["Wing" + S] = movekit.bone("Wing" + S, "Slipper" + S, root - hinge * 0.4, root + hinge * 0.6, "wing")
    hi, lo = BOW.z - 0.07, BOW.z - 0.25          # a strand hands over from the bow to its slipper here

    def weigh(piece, tag, co):
        if isinstance(tag, tuple):
            kind, s = tag
            if kind == "slipper":
                return {"Slipper" + _side(s): 1.0}
            if kind == "wing":
                return {"Wing" + _side(s): 1.0}
            if kind == "strand":
                return movekit.mix({"Slipper" + _side(s): 1.0}, {"Ribbon": 1.0}, movekit.smooth(lo, hi, co.z))
        return {"Ribbon": 1.0}
    return movekit.skin(name, objs, bones, weigh)


# test poses for preview.py --pose (rigging.apply_pose: world axes, degrees)
POSES = {
    "rest": {},
    # mid-dash: the pair swings back under the fist, the slippers apart, wings flapping up
    "dash": {"Ribbon": [((1, 0, 0), -25)], "SlipperL": [((0, 1, 0), -12)], "SlipperR": [((0, 1, 0), 12)],
             "WingL": [("own", -30)], "WingR": [("own", -30)]},
    # walking swing: one forward, one back
    "swing": {"SlipperL": [((1, 0, 0), 28)], "SlipperR": [((1, 0, 0), -28)], "WingL": [("own", 25)],
              "WingR": [("own", 25)]},
    # the limits: the slippers swung wide apart, the wings flapped right down
    "wide": {"SlipperL": [((0, 1, 0), -35)], "SlipperR": [((0, 1, 0), 35)], "WingL": [("own", 40)],
             "WingR": [("own", 40)]},
    "flap": {"WingL": [("own", -40)], "WingR": [("own", -40)]},
}
