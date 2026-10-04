"""
items/alarmduck.py - the AlarmDuck item (ReplicatedStorage.ItemMeshes.AlarmDuck) and its golden
version AlarmDuck_Gold: the Rubber Duck Alarm a player sets down in their own drawer. See
items/__init__.py for the conventions, items/defencekit.py for the shared helpers.

The same family as the bedroom's rubber duck (props/duck.py): its body, head, bill and wing shapes
and its colours are reused (a little coarser - this one is small; the head and the bill a touch
bigger, so it reads bolder), but this duck is on duty: big googly eyes with stern ink brows, its
bill a little open (a dark mouth and a pink tongue inside; the bill opens wider on a honk), a gold
security-star badge on its chest, a glossy highlight on its head, and a police-style beacon strapped
to its head - a dark base with a chrome rim, a chin strap down both cheeks with a chrome buckle, and
a squat, fluted red beacon (`AlarmDuck_Glow`, untextured: the game turns it into Neon and flashes it)
with glassy highlight streaks down its front.

The golden one: the same duck in polished gold with a copper-gold bill, the beacon's base wears a
gem-studded crown, the badge is a gem star, glitter sparkles on the body (`AlarmDuck_Gold_Glow` is
its beacon, the same shape).

1 unit = 1 stud: ~1.35 tall (the duck ~1.15, the beacon on top), ~1.0 wide, ~1.25 long. Origin = the
floor centre (it sits there: `_Base`); `_Grip` = under its body (the game turns it for holding).

The skeleton (`rig`, the same for both): `Root` at the floor centre (unweighted); `Body` (child of
Root) from the floor straight up through the body (local +Z = front: rocking it about its local Z
waddles the duck side to side, pivoting on the floor); `Head` (child of Body) from the neck straight
up through the head and the beacon (local +Y = up, +Z = front: turning it about its own Y turns the
head - beacon, strap, eyes and bill with it - toward an intruder); `Bill` (child of Head) from the
bill's hinge forward along the lower bill (local +Y = forward, +Z = up: turning it about its local -X,
i.e. model +X, opens the bill - built 14 degrees open, it closes at about -14 and opens cleanly to
+35 more; the dark mouth stretches between the bills); `Tail` (child of Body) from inside the rear
up and back through the tail tip (turning it about its local Z / X waggles the tail). The body is
weighted to Body, the tail's lobe blends to Tail; head, eyes, brows, the upper bill, the beacon (and
the glow part) ride Head rigidly; the lower bill and the tongue ride Bill; the mouth blends Head ->
Bill by its angle round the hinge. `POSES` holds preview.py's test poses.
"""
import math

import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

import items
import sockkit as K
from sockkit import M, hexcol
from props import duck as D
from items import defencekit as DK

NAME = "AlarmDuck"

MATERIALS = {"alarmduck_chrome": "metal", "alarmduck_base": "plastic", "alarmduck_glint": "decal",
             "alarmduck_tongue": "plastic", "alarmduck_mouth": "ink", "alarmduck_brow": "ink", "alarmduck_dome": "glass",
             "alarmduck_eye": "eye", "alarmduck_pupil": "ink", "alarmduck_badge": "metal", "alarmduck_patch": "fabric",
             "alarmduck_gloss": "decal",
             "alarmduck_strap": "rubber", "alarmduck_gold": "metal", "alarmduck_gem": "glass",
             "alarmduck_sparkle": "decal", "alarmduck_gold_shine": "decal", "alarmduck_gold_bill": "metal"}


def _palette(gold):
    """Registers this item's palette colours (called by build(), never at import: see
    items/__init__.py) -> {part: colour or tones}. The duck's own colours come from props/duck.py."""
    P = {"gold": gold}
    P["chrome"] = (hexcol("alarmduck_chrome_light", "#F1F3F8"), hexcol("alarmduck_chrome", "#BAC1D0"),
                   hexcol("alarmduck_chrome_dark", "#7E8699"))
    P["base"] = (hexcol("alarmduck_base_light", "#5E6478"), hexcol("alarmduck_base", "#3E4256"),
                 hexcol("alarmduck_base_dark", "#2A2C3C"))
    P["mouth"] = hexcol("alarmduck_mouth", "#7A1F2A")
    P["tongue"] = hexcol("alarmduck_tongue", "#F0627A")
    P["brow"] = hexcol("alarmduck_brow", "#2A1A14")
    P["dome"] = hexcol("alarmduck_dome", "#FF3B3B")   # the glow part's preview colour (the game makes it Neon)
    P["glint"] = hexcol("alarmduck_glint", "#FFFFFF")
    P["eye"] = hexcol("alarmduck_eye_white", "#FBFBF6")
    P["pupil"] = hexcol("alarmduck_pupil", "#1C1420")
    P["strap"] = hexcol("alarmduck_strap", "#3A3E52")
    P["gloss"] = hexcol("alarmduck_gloss", "#FFF7D6")
    # the security patch on the chest: a navy shield with a star
    P["patch"] = (hexcol("alarmduck_patch", "#2F55B8"), hexcol("alarmduck_patch_rim", "#F4F6FF"))
    if not gold:
        P["badge"] = (hexcol("alarmduck_badge", "#F4F6FF"), hexcol("alarmduck_badge_rim", "#C98A16"))
        P["body"] = (D.D_TOP, D.D_BASE, D.D_SHADE, D.D_DEEP)
        P["bill"] = (D.B_TOP, D.B_BASE, D.B_LOW, D.B_LOW_SH)
        P["wing"] = (D.D_SHADE, D.D_DEEP)
        P["ink"] = D.INK
    else:
        G = DK.gold_colours("alarmduck")
        P.update(G)
        P["badge"] = (G["gold"][1], G["gold"][3])
        P["body"] = G["gold"]
        P["bill"] = (hexcol("alarmduck_gold_bill_light", "#FFD2A0"), hexcol("alarmduck_gold_bill", "#FF8F3A"),
                     hexcol("alarmduck_gold_bill_dark", "#D0601C"), hexcol("alarmduck_gold_bill_deep", "#93400F"))
        P["wing"] = (G["gold"][2], G["gold"][3])
        P["ink"] = hexcol("alarmduck_gold_ink", "#8A4A10")
    return P


S = 0.232                      # prop units -> studs (the bedroom duck is ~4.8 units tall)
OUTLINE_W = 0.038              # in studs
HEAD_K = 1.06                  # the head a touch bigger than the bedroom duck's ...
BILL_K = 1.12                  # ... and the bill
BILL_PIVOT = Vector((0.0, -1.35, 3.15))   # (prop units) the bills grow from here
HINGE = Vector((0.0, -1.42, 3.1))         # the lower bill's hinge (prop units) ...
OPEN = 0.25                    # ... and how far it is open at rest (rad)
HEAD_C = D.HEAD_C
HEAD_R = D.HEAD_R * HEAD_K
TOP = HEAD_C.z + HEAD_R * D.HEAD_S[2]     # top of the head (prop units)
SIREN_Y = -0.6                 # the beacon sits a touch forward of the crown (prop units)
BASE_R, BASE_H = 0.86, 0.36    # beacon base (prop units)
DOME_R, DOME_H = 0.7, 0.86     # the beacon: fluted straight sides, a round top
FLUTES = 12
TAIL_TIP = Vector((0.0, 2.62, 2.89))      # (prop units) from props/duck.py's shape
TAIL_BASE = Vector((0.0, 2.0, 2.15))
GRIP = Vector((0.0, 0.2 * S, 0.06))


def _head_point(y):
    """Point on the top of the head above (0, y) (prop units)."""
    dy = (y - HEAD_C.y) / (HEAD_R * D.HEAD_S[1])
    return HEAD_C.z + HEAD_R * D.HEAD_S[2] * math.sqrt(max(0.0, 1 - dy * dy))


def _surface(az, el, lift=0.0):
    """Point and normal on the (bigger) head at azimuth az (0 = front, + toward +X), elevation el."""
    d = Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))
    sc = D.HEAD_S
    p = HEAD_C + Vector((d.x * sc[0], d.y * sc[1], d.z * sc[2])) * HEAD_R
    n = Vector((d.x / sc[0], d.y / sc[1], d.z / sc[2])).normalized()
    return p + n * lift, n


def _blob(P, fn, part, name, seg, rings, cuts, pal, outline=True, **kw):
    """D._blob toned like the bedroom duck, or (golden) polished metal banding."""
    if P["gold"] and part:
        cols = P[part]
        return D._blob(fn, lambda v: DK.metal_tone(cols, v), seg=seg, rings=rings, name=name, outline=outline,
                       cuts=DK.GOLD_CUTS, field=lambda co, n: DK.metal_value(n), **kw)
    return D._blob(fn, pal, seg=seg, rings=rings, name=name, outline=outline, cuts=cuts, **kw)


def _head_fn(q):
    return HEAD_C + (Vector(D._head(q)) - HEAD_C) * HEAD_K


def _bill_fn(fn):
    return lambda q: BILL_PIVOT + (Vector(fn(q)) - BILL_PIVOT) * BILL_K


def _duck(P, hull=False):
    """The duck itself, in prop units: -> [(piece, rig tag)]. hull=True: coarse copies of the big
    shapes for the outline hull only."""
    k = 0.6 if hull else 1.0
    seg = (lambda n: max(10, int(n * k)))
    body = _blob(P, D._body, "body", "body", seg(30), seg(18), (-0.55, -0.12, 0.82), D._body_pal,
                 dense=(D.TAIL_DIR, 0.55, 0.9))
    head = _blob(P, _head_fn, "body", "head", seg(26), seg(15), (-0.6, 0.8), D._head_pal)
    up = _blob(P, _bill_fn(D._upper_bill), "bill", "bill_up", seg(22), seg(12), (0.9,), D._upper_bill_pal)
    low = _blob(P, _bill_fn(D._lower_bill), "bill", "bill_low", seg(18), seg(10), (-0.3,), D._lower_bill_pal)
    low.mesh.transform(Matrix.Translation(HINGE) @ Matrix.Rotation(OPEN, 4, "X") @ Matrix.Translation(-HINGE))
    out = [(body, "body"), (head, "Head"), (up, "Head"), (low, "Bill")]
    me = body.mesh
    bvh = BVHTree.FromPolygons([v.co.copy() for v in me.vertices], [tuple(f.vertices) for f in me.polygons])
    for side in (-1, 1):
        wing, strokes = D._wing(side, bvh)
        wpal = (lambda nz: P["wing"][1] if nz < -0.45 else P["wing"][0])
        out.append((D._blob(wing, wpal, seg=seg(20), rings=seg(10), name="wing", cuts=(-0.45,), pole="x"), "Body"))
        if hull:
            continue
        for pts in strokes:
            out.append((K.tube(P["ink"], pts, radius=0.055, radii=[0.2, 0.75, 1.0, 1.0, 0.75, 0.2], res=2, bevel_res=1,
                               outline=False, name="wing_ink"), "Body"))
    if hull:
        return out, bvh
    # the mouth between the bills (stretches as the bill opens) and the tongue on the lower bill
    out.append((K.sphere(P["mouth"], 1.0, M((0, D.BILL_Y + 0.2, 3.03), rot=(OPEN * 0.5, 0, 0), scale=(0.7, 0.55, 0.2)),
                         seg=14, rings=8, outline=False, name="mouth"), "mouth"))
    out.append((K.sphere(P["tongue"], 1.0, M((0, D.BILL_Y + 0.08, 2.98), rot=(OPEN * 0.85, 0, 0), scale=(0.42, 0.28, 0.07)),
                         seg=12, rings=6, outline=False, name="tongue"), "Bill"))
    for side in (-1, 1):
        # googly eyes: a big white, a pupil glaring forward and in, a glint
        az, el = side * 0.66, 0.24
        pos, n = _surface(az, el)
        rot = n.to_track_quat("Z", "Y").to_matrix().to_4x4()
        out.append((K.sphere(P["eye"], 1.0, Matrix.Translation(pos + n * 0.02) @ rot @ Matrix.Diagonal((0.36, 0.4, 0.2, 1)),
                             seg=14, rings=8, outline=False, name="eye_white"), "Head"))
        look = (n + Vector((-side * 0.35, -0.5, -0.05))).normalized()
        pp = pos + n * 0.02 + look * 0.19
        prot = look.to_track_quat("Z", "Y").to_matrix().to_4x4()
        out.append((K.sphere(P["pupil"], 1.0, Matrix.Translation(pp) @ prot @ Matrix.Diagonal((0.17, 0.19, 0.06, 1)),
                             seg=12, rings=6, outline=False, name="pupil"), "Head"))
        out.append((K.sphere(P["glint"], 0.055, M(pp + look * 0.05 + Vector((-0.05, 0, 0.07))), seg=8, rings=5,
                             outline=False, name="glint"), "Head"))
        # a stern brow: a thick ink stroke over the eye, low at the inner end (on duty!)
        brow = []
        for kk in range(5):
            t = kk / 4
            q, nn = _surface(side * (0.36 + 0.56 * t), 0.56 + 0.16 * t)
            brow.append(tuple(q + nn * 0.05))
        out.append((K.tube(P["brow"], brow, radius=0.1, radii=[0.75, 1.0, 1.0, 0.9, 0.55], res=3, bevel_res=1,
                           outline=False, name="alarmduck_brow"), "Head"))
    return out, bvh


def _strap(P):
    """The chin strap from the beacon's base down both cheeks, with a chrome buckle (Head)."""
    out = []
    for side in (-1, 1):
        def surf(t, a, side=side):
            el = 0.88 - 1.38 * t                   # from under the base down past the cheek
            az = side * (1.22 + 0.22 * t) + a * 0.13
            return _surface(az, el)
        out.append(DK.ribbon(surf, 0.0, 1.0, 0.0, 1.0, P["strap"], n=14, lift=0.025, name="strap", taper=False))
        p, n = surf(0.62, 0.0)
        sq = [(-0.13, -0.11), (0.13, -0.11), (0.13, 0.11), (-0.13, 0.11)]
        out.append(DK.flat_poly(P["chrome"][1], sq, p, n, lift=0.04, name="buckle"))
        out.append(DK.flat_poly(P["base"][2], [(x * 0.55, y * 0.45) for x, y in sq], p, n, lift=0.045, name="buckle_hole"))
    return out


def _siren(P):
    """The beacon's base (prop units): base, chrome rim, glints on the dome (the dome itself is the glow
    part), the golden one's crown. -> (pieces, top z of the base)."""
    z0 = _head_point(SIREN_Y) - 0.16            # sunk a little into the head
    zt = z0 + BASE_H
    out = []
    base = K.cylinder(P["base"][1], BASE_R, BASE_H, M((0, SIREN_Y, z0 + BASE_H / 2)), seg=24, radius2=BASE_R * 0.92,
                      name="siren_base")
    key = Vector((-0.6, -0.8, 0))
    K.recolor_by(base, lambda c, cur: P["base"][0] if c.z > zt - 1e-3 else
                 (P["base"][0] if (c - Vector((0, SIREN_Y, c.z))).normalized().dot(key) > 0.4 else
                  (P["base"][2] if (c - Vector((0, SIREN_Y, c.z))).normalized().dot(key) < -0.5 else P["base"][1])))
    out.append(base)
    if P["gold"]:
        out += _crown(P, zt)
    else:
        out.append(K.torus(P["chrome"][1], BASE_R * 0.93, 0.075, M((0, SIREN_Y, zt)), seg=24, mseg=6, name="siren_rim"))
        for kk in range(6):        # little chrome bolts round the base
            a = kk / 6 * math.tau + 0.3
            c = Vector((math.cos(a) * BASE_R * 0.97, SIREN_Y + math.sin(a) * BASE_R * 0.97, z0 + BASE_H * 0.5))
            out.append(DK.flat_poly(P["chrome"][0], DK.circle(0, 0, 0.07, 8), c, Vector((math.cos(a), math.sin(a), 0)),
                                    lift=0.01, name="bolt"))
    az = math.atan2(-0.55, 0.6)                 # the key light's side (from the front -Y toward +X)
    for (h0, h1, da, w) in ((0.18, 0.7, 0.0, 0.12), (0.1, 0.28, 0.45, 0.08)):
        pts = []
        for kk in range(5):
            h = h0 + (h1 - h0) * kk / 4
            r = _dome_r(h, az + da) + 0.025
            a = az + da
            pts.append((r * math.sin(a), SIREN_Y - r * math.cos(a), zt + h))
        out.append(K.tube(P["glint"], pts, radius=w * 0.5, radii=[0.5, 1.0, 1.0, 0.9, 0.4], res=2, bevel_res=1,
                          outline=False, name="dome_glint"))
    return out, zt


def _crown(P, zt):
    """The golden duck's beacon wears a crown: a gold band round the base, six points with balls on
    top, a gem on the band under every point."""
    out = []
    r = BASE_R * 0.97
    out.append(DK.lathe([(zt - 0.24, 0.0, "a"), (zt - 0.24, r, "a"), (zt + 0.06, r + 0.02, "a"), (zt + 0.08, r - 0.08, "a"),
                         (zt + 0.08, 0.0, None)], 24, M((0, SIREN_Y, 0), rot=(0, -math.pi / 2, 0)),
                        lambda tag, n: DK.metal_tone(P["gold"], DK.metal_value(n)), "crown_band"))
    for kk in range(6):
        a = kk / 6 * math.tau + math.pi / 6
        d = Vector((math.cos(a), math.sin(a), 0))
        c = Vector((0, SIREN_Y, 0)) + d * (r - 0.02)
        bm = bmesh.new()       # a four-sided point leaning out a little
        tip = c + Vector((0, 0, zt + 0.42)) + d * 0.06
        sd = Vector((-d.y, d.x, 0))
        quad = [c + sd * 0.16 + Vector((0, 0, zt)), c + d * 0.07 + Vector((0, 0, zt)), c - sd * 0.16 + Vector((0, 0, zt)),
                c - d * 0.09 + Vector((0, 0, zt))]
        vs = [bm.verts.new(q) for q in quad]
        tv = bm.verts.new(tip)
        for i in range(4):
            bm.faces.new((vs[i], vs[(i + 1) % 4], tv))
        bm.faces.new(list(reversed(vs)))
        DK.outward(bm)
        bm.normal_update()
        pal = [DK.metal_tone(P["gold"], DK.metal_value(f.normal)) for f in bm.faces]
        out.append(DK.piece(bm, pal, "crown_point", smooth_=False))
        out.append(K.sphere(P["gold"][0], 0.075, M(tip), seg=8, rings=5, outline=False, name="crown_ball"))
        g = DK.GEM_ORDER[kk % 5]
        out.append(DK.gem(P[g], c + d * 0.04 + Vector((0, 0, zt - 0.1)), d, 0.085, 0.06, facets=6, name="gem_" + g))
    return out


def _dome_r(h, a=0.0):
    """The beacon's radius at height h above its base: fluted straight sides, then a round top."""
    side = DOME_H - DOME_R * 0.8
    flute = 1.0 + 0.05 * math.cos(FLUTES * a)
    if h <= side:
        return DOME_R * flute
    t = min(1.0, (h - side) / (DOME_R * 0.8))
    return DOME_R * math.sqrt(max(0.0, 1.0 - t * t)) * (1.0 + (flute - 1.0) * (1.0 - t))


def _dome(zt, seg=36, rows=9):
    """The red beacon (prop units): a fluted lathe, closed at the bottom (sunk in the base) and the top."""
    bm = bmesh.new()
    rings = []
    hs = [-0.06, 0.0] + [DOME_H * (0.3 + 0.7 * kk / rows) for kk in range(rows)]
    for h in hs:
        rings.append([bm.verts.new((_dome_r(max(h, 0.0), a) * (0.9 if h < 0 else 1.0) * math.cos(a),
                                    SIREN_Y + _dome_r(max(h, 0.0), a) * (0.9 if h < 0 else 1.0) * math.sin(a), zt + h))
                      for a in (j / seg * math.tau for j in range(seg))])
    for i in range(len(rings) - 1):
        for j in range(seg):
            kk = (j + 1) % seg
            bm.faces.new((rings[i][j], rings[i][kk], rings[i + 1][kk], rings[i + 1][j]))
    top = bm.verts.new((0.0, SIREN_Y, zt + DOME_H))
    for j in range(seg):
        bm.faces.new((rings[-1][j], rings[-1][(j + 1) % seg], top))
    bm.faces.new(rings[0][::-1])
    DK.outward(bm)
    return K.Piece(K._bm_to_mesh(bm, "dome"), K.OUTLINE, True, True, "dome")


def _decor(P, bvh):
    """The chest badge, the gloss on the head and body, the golden one's sparkles -> pieces."""
    out = []
    hit = bvh.ray_cast(Vector((0.0, -10.0, 1.55)), Vector((0, 1, 0)))
    if hit[0] is not None:
        o = hit[0]
        du, dv, along = Vector((1, 0, 0)), Vector((0, 0.25, 1)).normalized(), Vector((0, 1, -0.25)).normalized()
        shield = [(-0.5, 0.42), (0.0, 0.52), (0.5, 0.42), (0.5, 0.0), (0.36, -0.32), (0.0, -0.56), (-0.36, -0.32), (-0.5, 0.0)]
        shield = DK.densify(shield, 0.08)
        out.append(DK.decal(bvh, DK.offset_poly(shield, 0.07), o, du, dv, along, 0.02, P["patch"][1], "patch_rim", step=0.12))
        out.append(DK.decal(bvh, shield, o, du, dv, along, 0.035, P["patch"][0], "patch", step=0.12))
        star = DK.star(0, -0.01, 0.34, 0.15, 5)
        out.append(DK.decal(bvh, star, o, du, dv, along, 0.05, P["badge"][0], "badge", step=0.12))
        if P["gold"]:
            out.append(DK.gem(P["diamond"], o - along * 0.07, -along, 0.13, 0.1, facets=8, name="gem_diamond"))
    # a glossy highlight: a curved streak on the head's upper left, a soft one on the back
    hbvh = DK.bvh_of([pc for pc in P["_head"]])
    arc = []
    for kk in range(9):
        a = math.radians(115 + 70 * kk / 8)
        arc.append((0.62 * math.cos(a), 0.62 * math.sin(a)))
    for kk in range(9):
        a = math.radians(185 - 70 * kk / 8)
        arc.append((0.48 * math.cos(a) + 0.04, 0.48 * math.sin(a) - 0.02))
    hc = Vector((-0.25, HEAD_C.y - 0.2, HEAD_C.z + 0.3))
    out.append(DK.decal(hbvh, arc, hc, Vector((1, 0, 0)), Vector((0, 0, 1)), Vector((0.55, 0.8, -0.2)).normalized(), 0.02,
                        P["gloss"], "gloss", step=0.12))
    if P["gold"]:
        for side in (-1, 1):      # diagonal shine bars on both flanks
            out += DK.shine_bars(bvh, Vector((side * 1.9, -0.6, 1.45)), Vector((0, side, 0)), Vector((0, 0, 1)),
                                 Vector((-side, 0, 0)), (0.5, 0.72), P["shine"], lift=0.025, step=0.12, tilt=0.5)
        for (o, d, r) in (((-6, 0.4, 1.9), (1, 0, 0), 0.24), ((6, -0.7, 1.7), (-1, 0, 0), 0.2),
                          ((-0.5, 1.5, 8), (0, 0, -1), 0.18), ((6, 1.3, 0.8), (-1, 0, 0), 0.22),
                          ((-6, -1.0, 0.7), (1, 0, 0), 0.16)):
            h = bvh.ray_cast(Vector(o), Vector(d))
            if h[0] is not None:
                out.append(DK.sparkle(P["sparkle"], h[0], h[1], r, spin=o[1], lift=0.02))
    return out


def build(gold=False):
    name = NAME + ("_Gold" if gold else "")
    P = _palette(gold)
    tagged, bvh = _duck(P)
    P["_head"] = [pc for pc, t in tagged if pc.name == "head"]
    p = [DK.tag(pc, t) for pc, t in tagged]
    hulls, _b = _duck(P, hull=True)
    for pc, t in tagged:            # the big shapes get the coarse hull copies instead
        if pc.name in ("body", "head", "bill_up", "bill_low", "wing"):
            pc.outline = False
    hull = [DK.tag(pc, t) for pc, t in hulls]
    for pc in _decor(P, bvh):
        p.append(DK.tag(pc, "Head" if pc.name == "gloss" else "Body"))
    p += DK.tag_all(_strap(P), "Head")
    siren, zt = _siren(P)
    p += DK.tag_all(siren, "Head")
    hull_dome, glow_dome = DK.tag(_dome(zt, seg=24, rows=6), "Head"), _dome(zt)
    DK.transform(p + hull + [hull_dome, glow_dome], Matrix.Scale(S, 4))
    body, outline = K.finish(p, name, outline_width=OUTLINE_W, outline_only=hull + [hull_dome])
    DK.no_bounce(outline)
    glow = K.plain_object([glow_dome], name + "_Glow")
    # no material (the game colours it), but a UV map on the red swatch so previews / Studio show it red
    gu, gv = K.swatch_uv(P["dome"])
    for d in glow.data.uv_layers.new(name="UVMap").data:
        d.uv = (gu, gv)
    for f in glow.data.polygons:
        f.use_smooth = True
    return [body, outline, glow] + K.markers(name) + [items.grip(name, GRIP)]


BUILDERS = {NAME: build, NAME + "_Gold": lambda: build(True)}


# ---------------------------------------------------------------- skeleton
def _tail_field(p):
    """Body -> Tail along the tail's lobe (p in studs)."""
    base, tip = TAIL_BASE * S, TAIL_TIP * S
    ax = tip - base
    s = (p - base).dot(ax) / ax.length_squared
    lat = (p - (base + ax * s)).length / (0.55 * S)
    t = DK.smooth(-0.05, 0.55, s) * (1.0 - DK.smooth(0.8, 1.4, lat))
    return DK.mix({"Body": 1.0}, {"Tail": 1.0}, t)


def _mouth_field(p):
    """Head -> Bill by the angle round the hinge (0 at the upper bill, OPEN at the lower one)."""
    h = HINGE * S
    v = p - h
    ang = math.atan2(-v.z, -v.y)      # below the forward line = positive
    return DK.mix({"Head": 1.0}, {"Bill": 1.0}, DK.smooth(-0.05, OPEN + 0.1, ang))


def rig(name, objs):
    """`<Name>_Rig`: Root (floor) + Body, Head, Bill, Tail (see the module doc); skins the body, the
    outline and the glow part (100% Head)."""
    s = S
    neck = Vector((0, HEAD_C.y, 2.55)) * s
    bones = [DK.Bone("Root", None, (0, 0, 0), (0, -0.3, 0), deform=False),
             DK.Bone("Body", "Root", (0, 0.2 * s, 0), (0, 0.2 * s, 2.0 * s)),
             DK.Bone("Head", "Body", neck, Vector((0, HEAD_C.y, TOP + 0.9)) * s),
             DK.Bone("Bill", "Head", HINGE * s, Vector((0, -2.45, HINGE.z)) * s, z=(0, 0, 1)),
             DK.Bone("Tail", "Body", (TAIL_BASE - (TAIL_TIP - TAIL_BASE) * 0.25) * s, TAIL_TIP * s)]
    fields = {"body": _tail_field, "mouth": _mouth_field}
    glow = next(o for o in objs if o.name.endswith("_Glow"))
    return DK.skin(name, objs, bones, fields, rigid={glow.name: "Head"})


OPEN_X = (1, 0, 0)       # model +X: opens the bill (Bill), nods the head down (Head)
POSES = {
    "rest": {},
    "honk": {"Bill": [(OPEN_X, 35)], "Head": [((1, 0, 0), -12)], "Body": [((1, 0, 0), -5)]},
    "shut": {"Bill": [(OPEN_X, -14)]},
    "look": {"Head": [(("own"), 50)], "Tail": [((0, 0, 1), 25)]},
    "waddle": {"Body": [(("local", 0, 0, 1), 12)], "Head": [(("local", 0, 0, 1), -8)], "Tail": [((1, 0, 0), -20)]},
    "tail": {"Tail": [((0, 0, 1), 35), ((1, 0, 0), -25)]},
}
