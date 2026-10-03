"""
items/alarmduck.py - the AlarmDuck item (ReplicatedStorage.ItemMeshes.AlarmDuck): the Rubber Duck Alarm
a player sets down in their own drawer. See items/__init__.py for the conventions.

The same family as the bedroom's rubber duck (props/duck.py): its body, head, bill and wing shapes
and its colours are reused (built a little coarser - this one is small), but this duck is on duty:
its bill is open mid-QUACK (the lower bill hinged down over a dark mouth), stern ink brows sit over
its eyes, and a police-style beacon is strapped to its head - a dark base with a chrome rim and a
red beacon (`AlarmDuck_Glow`, untextured: the game turns it into Neon and flashes it) with a glassy
highlight streak down its front.

1 unit = 1 stud: ~1.4 tall (the duck ~1.1, the siren on top), ~1.0 wide, ~1.25 long. Origin = the
floor centre (it sits there: `_Base`); `_Grip` = under its body (the game turns it for holding).
"""
import math
import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
import sockkit as K
from sockkit import M, hexcol
import items
from props import duck as D
from props.slippers import _outward
from items.staticballoon import no_bounce

NAME = "AlarmDuck"

MATERIALS = {"alarmduck_chrome": "metal", "alarmduck_base": "plastic", "alarmduck_glint": "decal",
             "alarmduck_tongue": "plastic", "alarmduck_mouth": "ink", "alarmduck_brow": "ink", "alarmduck_dome": "glass"}


def _colours():
    """Registers this item's palette colours. Called by build(), not at import: build_all.py imports
    every item module before it builds the socks, so colours registered at import would take palette
    cells ahead of the socks' (items must come last, see items/__init__.py)."""
    global CHROME, BASE, MOUTH, TONGUE, BROW, DOME, GLINT
    CHROME = (hexcol("alarmduck_chrome_light", "#F1F3F8"), hexcol("alarmduck_chrome", "#BAC1D0"),
              hexcol("alarmduck_chrome_dark", "#7E8699"))
    BASE = (hexcol("alarmduck_base_light", "#5E6478"), hexcol("alarmduck_base", "#3E4256"), hexcol("alarmduck_base_dark", "#2A2C3C"))
    MOUTH = hexcol("alarmduck_mouth", "#7A1F2A")
    TONGUE = hexcol("alarmduck_tongue", "#F0627A")
    BROW = hexcol("alarmduck_brow", "#2A1A14")
    DOME = hexcol("alarmduck_dome", "#FF3B3B")   # the glow part's preview colour (the game makes it Neon)
    GLINT = hexcol("alarmduck_glint", "#FFFFFF")


S = 0.232                      # prop units -> studs (the bedroom duck is ~4.8 units tall)
OUTLINE_W = 0.038              # in studs
HINGE = Vector((0.0, -1.48, 3.1))   # the lower bill's hinge (prop units) ...
OPEN = 0.6                     # ... and how far it drops open (rad)
TOP = D.HEAD_C.z + D.HEAD_R * D.HEAD_S[2]   # top of the head (prop units)
SIREN_Y = -0.62                # the siren sits a touch forward of the crown (prop units)
BASE_R, BASE_H = 0.78, 0.34    # siren base (prop units)
DOME_R, DOME_H = 0.62, 1.0     # dome: a beacon (straight sides, a round top)
GRIP = Vector((0.0, 0.2 * S, 0.06))


def _head_point(y):
    """Point on the top of the head above (0, y) (prop units)."""
    dy = (y - D.HEAD_C.y) / (D.HEAD_R * D.HEAD_S[1])
    return D.HEAD_C.z + D.HEAD_R * D.HEAD_S[2] * math.sqrt(max(0.0, 1 - dy * dy))


def _duck():
    """The duck itself, in prop units (props/duck.py's shapes, a little coarser, bill open)."""
    body = D._blob(D._body, D._body_pal, seg=28, rings=18, name="body", cuts=(-0.55, -0.12, 0.82),
                   dense=(D.TAIL_DIR, 0.55, 0.9))
    p = [body,
         D._blob(D._head, D._head_pal, seg=24, rings=14, name="head", cuts=(-0.6, 0.8)),
         D._blob(D._upper_bill, D._upper_bill_pal, seg=22, rings=12, name="bill_up", cuts=(0.9,))]
    low = D._blob(D._lower_bill, D._lower_bill_pal, seg=16, rings=9, name="bill_low", cuts=(-0.3,))
    low.mesh.transform(Matrix.Translation(HINGE) @ Matrix.Rotation(OPEN, 4, "X") @ Matrix.Translation(-HINGE))
    p.append(low)
    # the mouth between the bills: a dark wedge with a pink tongue on its floor
    p.append(K.sphere(MOUTH, 1.0, M((0, D.BILL_Y + 0.15, 3.0), rot=(OPEN * 0.5, 0, 0), scale=(0.66, 0.45, 0.2)),
                      seg=14, rings=8, outline=False, name="mouth"))
    p.append(K.sphere(TONGUE, 1.0, M((0, D.BILL_Y + 0.05, 2.96), rot=(OPEN * 0.8, 0, 0), scale=(0.4, 0.26, 0.06)),
                      seg=12, rings=6, outline=False, name="tongue"))
    me = body.mesh
    bvh = BVHTree.FromPolygons([v.co.copy() for v in me.vertices], [tuple(f.vertices) for f in me.polygons])
    for side in (-1, 1):
        wing, strokes = D._wing(side, bvh)
        p.append(D._blob(wing, lambda nz: D.D_DEEP if nz < -0.45 else D.D_SHADE, seg=20, rings=10, name="wing",
                         cuts=(-0.45,), pole="x"))
        for pts in strokes:
            p.append(K.tube(D.INK, pts, radius=0.05, radii=[0.2, 0.75, 1.0, 1.0, 0.75, 0.2], res=3, bevel_res=1,
                            outline=False, name="wing_ink"))
        az, el = side * 0.74, 0.23
        pos, d = D._surface(D.HEAD_C, D.HEAD_R, D.HEAD_S, az, el)
        p.append(K.sphere(D.EYE, 1.0, M(pos - d * 0.04, rot=(-el, 0, az), scale=(0.215, 0.12, 0.24)), seg=12, rings=8,
                          outline=False, name="eye"))
        g = pos + d * 0.05 + Vector((-side * 0.045, -0.04, 0.08))
        p.append(K.sphere(K.WHITE, 0.05, M(g), seg=8, rings=5, outline=False, name="glint"))
        # a stern brow: an ink stroke over the eye, low at the inner end (on duty!)
        brow = []
        for k in range(5):
            t = k / 4
            a2 = side * (0.42 + 0.5 * t)
            e2 = 0.5 + 0.12 * t
            q, n = D._surface(D.HEAD_C, D.HEAD_R, D.HEAD_S, a2, e2)
            brow.append(tuple(q + n * 0.03))
        p.append(K.tube(BROW, brow, radius=0.075, radii=[0.7, 1.0, 1.0, 0.9, 0.5], res=3, bevel_res=1, outline=False,
                        name="alarmduck_brow"))
    return p


def _siren():
    """The siren on the head (prop units): the base, its chrome rim and a glint on the beacon. The
    beacon itself is built separately (the glow part)."""
    z0 = _head_point(SIREN_Y) - 0.12            # sunk a little into the head
    out = []
    base = K.cylinder(BASE[1], BASE_R, BASE_H, M((0, SIREN_Y, z0 + BASE_H / 2)), seg=22, radius2=BASE_R * 0.9,
                      name="siren_base")
    K.recolor_by(base, lambda c, cur: BASE[0] if c.z > z0 + BASE_H - 1e-3 else
                 (BASE[0] if (c - Vector((0, SIREN_Y, c.z))).dot(Vector((-0.6, -0.8, 0))) > 0.3 else BASE[1]))
    out.append(base)
    out.append(K.torus(CHROME[1], BASE_R * 0.9, 0.06, M((0, SIREN_Y, z0 + BASE_H)), seg=24, mseg=6, name="siren_rim"))
    zt = z0 + BASE_H
    # a glassy highlight down the beacon's front-left (in the body: the dome itself is the glow part)
    az = math.atan2(-0.55, 0.6)   # heading of the key light side (from the front -Y toward +X)
    for (z0g, z1g, da, w) in ((0.22, 0.78, 0.0, 0.1), (0.12, 0.3, 0.42, 0.07)):
        pts = []
        for k in range(5):
            zz = z0g + (z1g - z0g) * k / 4
            r = _dome_r(zz) + 0.02
            a = az + da
            pts.append((r * math.sin(a), SIREN_Y - r * math.cos(a), zt + zz))
        out.append(K.tube(GLINT, pts, radius=w * 0.5, radii=[0.5, 1.0, 1.0, 0.9, 0.4], res=3, bevel_res=1,
                          outline=False, name="dome_glint"))
    return out, zt


def _dome_r(h):
    """The beacon's radius at height h above its base: straight sides, then a round top."""
    side = DOME_H - DOME_R * 0.85
    if h <= side:
        return DOME_R
    t = min(1.0, (h - side) / (DOME_R * 0.85))
    return DOME_R * math.sqrt(max(0.0, 1.0 - t * t))


def _dome(zt, seg=20, rows=10):
    """The red beacon (prop units): a lathe, closed at the bottom (sunk in the base) and the top."""
    bm = bmesh.new()
    rings = []
    hs = [-0.05, 0.0] + [DOME_H * (0.35 + 0.65 * k / rows) for k in range(rows)]
    for h in hs:
        r = _dome_r(max(h, 0.0)) * (0.9 if h < 0 else 1.0)
        rings.append([bm.verts.new((r * math.cos(a), SIREN_Y + r * math.sin(a), zt + h))
                      for a in (j / seg * math.tau for j in range(seg))])
    for i in range(len(rings) - 1):
        for j in range(seg):
            k = (j + 1) % seg
            bm.faces.new((rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]))
    top = bm.verts.new((0.0, SIREN_Y, zt + DOME_H))
    for j in range(seg):
        bm.faces.new((rings[-1][j], rings[-1][(j + 1) % seg], top))
    bm.faces.new(rings[0][::-1])
    _outward(bm)
    return K.Piece(K._bm_to_mesh(bm, "dome"), DOME, True, True, "dome")


def build():
    _colours()
    duck = _duck()
    siren, zt = _siren()
    scale = Matrix.Scale(S, 4)
    p = duck + siren
    hull_dome = _dome(zt)
    glow_dome = _dome(zt)
    for pc in p + [hull_dome, glow_dome]:
        pc.mesh.transform(scale)
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W, outline_only=[hull_dome])
    no_bounce(outline)
    glow = K.plain_object([glow_dome], NAME + "_Glow")
    # no material (the game colours it), but a UV map on the red swatch so previews / Studio show it red
    gu, gv = K.swatch_uv(DOME)
    for d in glow.data.uv_layers.new(name="UVMap").data:
        d.uv = (gu, gv)
    for f in glow.data.polygons:
        f.use_smooth = True
    return [body, outline, glow] + K.markers(NAME) + [items.grip(NAME, GRIP)]


BUILDERS = {NAME: build}
