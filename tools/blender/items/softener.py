"""
items/softener.py - the Softener Cloud's two models (see items/__init__.py for the conventions):

SoftenerBottle (ReplicatedStorage.ItemMeshes.SoftenerBottle): a pink fabric-softener spray bottle. A
chunky bottle with a soft squarish cross-section (one loft of superellipse rings: a rounded foot, a
slight waist, sloping shoulders, a short neck), a ribbed screw collar, a lilac trigger-sprayer head
with its nozzle pointing FRONT (-Y), a purple trigger under it, and a cute label front and back: a
smiling white cloud on a sky-blue patch with a few sparkles. 1 unit = 1 stud: ~1.6 tall. Origin =
floor centre; `_Grip` = the neck under the sprayer head (the fist round the neck, the nozzle pointing
forward out of it), `_Tip` = the nozzle's mouth (where the spray comes out).

SoftenerPuff (ReplicatedStorage.ItemMeshes.SoftenerPuff): one fluffy cloud puff, ~3 wide; the game
places several, scaled, to make the softener cloud. One closed lumpy surface: every vertex of an
icosphere is pushed out to a smooth union of a dozen round lobes (seen from the middle), so the
lumps blend with soft creases. The ink hull is a softer-creased copy of the same heap (an exact
copy's hull folds through the surface in the creases and draws dark scratches there). Pastel pink on
top fading to lavender underneath, cut along normal iso-lines. No grip; origin = the bottom centre.
"""
import math
import bmesh
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
import items
from props.slippers import _iso_cut, _outward
from items.staticballoon import bvh_of, decal, no_bounce, offset_poly, tone

BOTTLE = "SoftenerBottle"
PUFF = "SoftenerPuff"

MATERIALS = {"softener_bottle": "plastic", "softener_head": "plastic", "softener_trigger": "plastic",
             "softener_nozzle": "plastic", "softener_label": "paper", "softener_cloud": "paper",
             "softener_spark": "decal", "softener_puff": "fluff"}


def _colours():
    """Registers this item's palette colours. Called by build(), not at import: build_all.py imports
    every item module before it builds the socks, so colours registered at import would take palette
    cells ahead of the socks' (items must come last, see items/__init__.py)."""
    global PINK, HEAD, TRIG, NOZ_HOLE, LABEL, CLOUD, FACE, CHEEK, SPARK, PUFF_COL
    PINK = (hexcol("softener_bottle_light", "#FFC4E0"), hexcol("softener_bottle", "#FF8DC3"),
            hexcol("softener_bottle_dark", "#E35E9F"))
    HEAD = (hexcol("softener_head_light", "#FBF7FF"), hexcol("softener_head", "#E4D9F7"),
            hexcol("softener_head_dark", "#B9A9DE"))
    TRIG = (hexcol("softener_trigger_light", "#C9A6FF"), hexcol("softener_trigger", "#A57BEB"),
            hexcol("softener_trigger_dark", "#7C55C4"))
    NOZ_HOLE = hexcol("softener_nozzle_hole", "#3A2550")
    LABEL = (hexcol("softener_label", "#BDE7FF"), hexcol("softener_label_rim", "#FFFFFF"))
    CLOUD = (hexcol("softener_cloud", "#FFFFFF"), hexcol("softener_cloud_shade", "#E3EEFC"))
    FACE = hexcol("softener_cloud_mouth", "#4A2E5E")      # "mouth" -> ink: eyes and smile stay crisp
    CHEEK = hexcol("softener_cloud_cheek", "#FFA8CC")
    SPARK = hexcol("softener_spark", "#FFE27A")
    PUFF_COL = (hexcol("softener_puff_light", "#FFDFF0"), hexcol("softener_puff", "#F8C2E2"),
                hexcol("softener_puff_dark", "#DDB2EC"), hexcol("softener_puff_deep", "#BFA2E4"))


OUTLINE_W = 0.04
CUTS = (-0.4, 0.62)
# bottle loft stations: (z, half width x, half depth y)
STATIONS = [(0.0, 0.27, 0.18), (0.035, 0.345, 0.235), (0.11, 0.375, 0.262), (0.42, 0.355, 0.248), (0.78, 0.372, 0.26),
            (0.9, 0.34, 0.24), (0.98, 0.25, 0.19), (1.03, 0.16, 0.15), (1.06, 0.13, 0.13), (1.09, 0.13, 0.13)]
SQ = 3.0                      # superellipse exponent of the cross-section
NECK_Z = 1.09
HEAD_Z = 1.34                 # sprayer head centre height
NOZZLE = Vector((0.0, -0.43, 1.38))
GRIP_B = Vector((0.0, 0.0, 1.02))
SCALE_B = 1.09                # the whole bottle (built ~1.47 tall) -> ~1.6


def _interp(z, col):
    st = STATIONS
    if z <= st[0][0]:
        return st[0][col]
    i = max(k for k in range(len(st) - 1) if st[k][0] <= z)
    i = min(i, len(st) - 2)
    a, b, c, d = (st[min(max(k, 0), len(st) - 1)][col] for k in (i - 1, i, i + 1, i + 2))
    t = (z - st[i][0]) / (st[i + 1][0] - st[i][0])
    return 0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t ** 3)


def _sq(a):
    c, s = math.cos(a), math.sin(a)
    return math.copysign(abs(c) ** (2 / SQ), c), math.copysign(abs(s) ** (2 / SQ), s)


def _bottle(seg=28, rows=26):
    bm = bmesh.new()
    rings = []
    zs = [NECK_Z * (i / rows) for i in range(rows + 1)]
    for z in zs:
        hx, hy = _interp(z, 1), _interp(z, 2)
        ring = []
        for j in range(seg):
            cx, cy = _sq(j / seg * math.tau)
            ring.append(bm.verts.new((cx * hx, cy * hy, z)))
        rings.append(ring)
    for i in range(rows):
        a, b = rings[i], rings[i + 1]
        for j in range(seg):
            k = (j + 1) % seg
            bm.faces.new((a[j], a[k], b[k], b[j]))
    bm.faces.new(rings[0][::-1])
    bm.faces.new(rings[-1])
    _outward(bm)
    bm.normal_update()
    nz = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, nz, CUTS)
    pal = [tone(PINK, sum(nz[v] for v in f.verts) / len(f.verts), CUTS) for f in bm.faces]
    pc = K.Piece(K._bm_to_mesh(bm, "bottle"), pal, True, True, "bottle")
    pc.flat_faces = [i for i, f in enumerate(pc.mesh.polygons) if len(f.vertices) > 4]
    return pc


def _cyl(cols, r, z0, z1, seg=18, name="cyl", r2=None, outline=True):
    pc = K.cylinder(cols[1], r, z1 - z0, M((0, 0, (z0 + z1) / 2)), seg=seg, radius2=r2, name=name, outline=outline)
    K.recolor_by(pc, lambda c, cur: cols[0] if c.z > z1 - 1e-4 else cur)
    return pc


def _head():
    """The trigger sprayer: ribbed collar, the head (a chunky shroud, taller at the back, its nose
    reaching forward over the trigger), the nozzle and the trigger."""
    out = []
    out.append(_cyl(HEAD, 0.165, NECK_Z - 0.04, NECK_Z + 0.1, seg=22, name="collar"))
    for k in range(5):   # ribs round the collar
        z = NECK_Z - 0.02 + 0.026 * k
        out.append(K.torus(HEAD[2], 0.168, 0.01, M((0, 0, z)), seg=22, mseg=4, outline=False, name="rib"))
    out.append(_cyl(HEAD, 0.12, NECK_Z + 0.09, NECK_Z + 0.17, seg=16, name="stem"))
    shroud = K.rounded_box(HEAD[1], (0.27, 0.5, 0.26), M((0, -0.07, HEAD_Z)), bevel=0.11, segments=3, name="head")
    K.recolor_by(shroud, lambda c, cur: HEAD[0] if c.z > HEAD_Z + 0.1 else (HEAD[2] if c.z < HEAD_Z - 0.1 else HEAD[1]))
    out.append(shroud)
    # the nose: a narrower block sloping down to the nozzle
    nose = K.rounded_box(HEAD[1], (0.2, 0.16, 0.17), M((0, -0.33, NOZZLE.z), rot=(0.12, 0, 0)), bevel=0.07, segments=3,
                         name="head_nose")
    K.recolor_by(nose, lambda c, cur: HEAD[0] if c.z > NOZZLE.z + 0.06 else cur)
    out.append(nose)
    # nozzle: a little square-ish cap with the spray hole
    noz = K.rounded_box(TRIG[1], (0.15, 0.06, 0.15), M((NOZZLE.x, NOZZLE.y + 0.03, NOZZLE.z)), bevel=0.04, segments=2,
                        name="softener_nozzle")
    K.recolor_by(noz, lambda c, cur: TRIG[0] if c.z > NOZZLE.z + 0.05 else cur)
    out.append(noz)
    hole = K.cylinder(NOZ_HOLE, 0.028, 0.01, Matrix.Translation(NOZZLE) @ Matrix.Rotation(math.pi / 2, 4, "X"), seg=10,
                      outline=False, name="nozzle_hole")
    out.append(hole)
    # trigger: a curved lever hanging under the nose, flared at the bottom
    pts = [(0, -0.24, HEAD_Z - 0.06), (0, -0.3, HEAD_Z - 0.2), (0, -0.29, HEAD_Z - 0.33), (0, -0.25, HEAD_Z - 0.42)]
    trig = K.tube(TRIG[1], pts, radius=0.055, radii=[0.9, 1.0, 1.05, 0.95], res=4, bevel_res=2, name="trigger")
    K.recolor_by(trig, lambda c, cur: TRIG[0] if c.y < -0.31 else (TRIG[2] if c.y > -0.24 else TRIG[1]))
    # flatten it sideways a little (a lever, not a rod)
    trig.mesh.transform(Matrix.Diagonal((1.35, 1.0, 1.0, 1.0)))
    out.append(trig)
    return out


def _cloud_poly(w, h, n=72):
    """A cartoon cloud outline (CCW): the boundary of a few overlapping circles, flat-ish bottom."""
    circles = [((-0.55, -0.1), 0.42), ((0.55, -0.12), 0.4), ((-0.15, 0.2), 0.5), ((0.3, 0.18), 0.42),
               ((0.0, -0.18), 0.45), ((-0.85, -0.22), 0.25), ((0.85, -0.24), 0.24)]
    out = []
    for i in range(n):
        a = i / n * math.tau
        u = Vector((math.cos(a), math.sin(a)))
        best = 0.0
        for (cx, cy), r in circles:
            c = Vector((cx, cy))
            b = u.dot(c)
            disc = r * r - (c - u * b).length_squared
            if disc >= 0:
                best = max(best, b + math.sqrt(disc))
        out.append((u.x * best * w, u.y * best * h))
    return out


def _labels(bvh):
    out = []
    for face in (-1, 1):            # front (-Y) and back (+Y)
        along = Vector((0, -face, 0))
        du = Vector((-face, 0, 0))
        dv = Vector((0, 0, 1))
        o = Vector((0, face * 0.1, 0.5))
        rect = []
        hw, hh, rc = 0.27, 0.24, 0.1
        for (cx, cy, a0) in ((hw - rc, -hh + rc, -90), (hw - rc, hh - rc, 0), (-hw + rc, hh - rc, 90), (-hw + rc, -hh + rc, 180)):
            for k in range(6):
                a = math.radians(a0 + 90 * k / 5)
                rect.append((cx + rc * math.cos(a), cy + rc * math.sin(a)))
        out.append(decal(bvh, offset_poly(rect, 0.03), o, du, dv, along, 0.004, LABEL[1], "label_rim", step=0.07))
        out.append(decal(bvh, rect, o, du, dv, along, 0.008, LABEL[0], "label", step=0.07))
        cloud = _cloud_poly(0.17, 0.15)
        oc = o + Vector((0, 0, -0.02))
        out.append(decal(bvh, cloud, oc, du, dv, along, 0.012,
                         lambda q, n: CLOUD[1] if q.y < -0.06 else CLOUD[0], "cloud", step=0.035))
        if face < 0:   # the front cloud smiles: two eyes, a smile, pink cheeks
            for sx in (-1, 1):
                eye = [(sx * 0.055 + 0.016 * math.cos(a), 0.01 + 0.022 * math.sin(a)) for a in
                       (j / 10 * math.tau for j in range(10))]
                out.append(decal(bvh, eye, oc, du, dv, along, 0.016, FACE, "eye", step=0.05))
                ck = [(sx * 0.105 + 0.026 * math.cos(a), -0.035 + 0.016 * math.sin(a)) for a in
                      (j / 10 * math.tau for j in range(10))]
                out.append(decal(bvh, ck, oc, du, dv, along, 0.015, CHEEK, "cheek", step=0.05))
            smile = []
            for k in range(9):   # a thin crescent
                a = math.radians(200 + 140 * k / 8)
                smile.append((0.04 * math.cos(a), -0.02 + 0.03 * math.sin(a)))
            for k in range(9):
                a = math.radians(340 - 140 * k / 8)
                smile.append((0.034 * math.cos(a), -0.012 + 0.022 * math.sin(a)))
            out.append(decal(bvh, smile, oc, du, dv, along, 0.016, FACE, "smile", step=0.05))
        for (sx, sy, r) in ((-0.2, 0.15, 0.045), (0.21, 0.12, 0.035), (0.19, -0.16, 0.03)):   # sparkles
            star = []
            for k in range(8):
                a = k / 8 * math.tau + math.pi / 2
                rr = r if k % 2 == 0 else r * 0.32
                star.append((sx + rr * math.cos(a), sy + rr * math.sin(a)))
            out.append(decal(bvh, star, o, du, dv, along, 0.012, SPARK, "spark", step=0.05))
    return out


def build_bottle():
    _colours()
    bottle = _bottle()
    bvh = bvh_of([bottle])
    p = [bottle] + _head() + _labels(bvh)
    for pc in p:
        pc.mesh.transform(Matrix.Scale(SCALE_B, 4))
    body, outline = K.finish(p, BOTTLE, outline_width=OUTLINE_W)
    no_bounce(outline)
    tip = K.marker(BOTTLE + "_Tip", (NOZZLE + Vector((0, -0.01, 0))) * SCALE_B)
    return [body, outline] + K.markers(BOTTLE) + [items.grip(BOTTLE, GRIP_B * SCALE_B), tip]


# ---------------------------------------------------------------- the puff
PUFF_C = Vector((0.0, 0.0, 0.85))   # rays start here
# (centre, radius): a wide, soft heap of lobes, the biggest in the middle
LOBES = [((0.0, 0.0, 0.95), 0.82), ((0.82, 0.12, 0.72), 0.62), ((-0.85, -0.05, 0.7), 0.6), ((0.25, -0.62, 0.72), 0.55),
         ((-0.35, 0.6, 0.78), 0.55), ((0.4, 0.05, 1.35), 0.55), ((-0.38, -0.12, 1.3), 0.5), ((1.2, -0.25, 0.55), 0.38),
         ((-1.2, 0.3, 0.55), 0.4), ((0.6, 0.62, 0.62), 0.42), ((-0.6, -0.6, 0.58), 0.42), ((0.05, 0.25, 1.62), 0.3)]


def _puff_radius(u, k):
    """Distance from PUFF_C to the surface along u: a smooth max (sharpness k) of the lobes' far hits."""
    acc, vals = 0.0, []
    for c, r in LOBES:
        c = Vector(c) - PUFF_C
        b = u.dot(c)
        disc = r * r - (c - u * b).length_squared
        # far hit of the ray with the lobe; a ray that misses falls off smoothly instead of jumping
        # (a jump would tear a step into the surface where the lobe's edge is seen from the middle)
        vals.append(b + math.copysign(math.sqrt(abs(disc)), disc))
    m = max(vals)
    for v in vals:
        acc += math.exp(k * (v - m))
    return m + math.log(acc) / k


def _puff(k=9.0, hull=False):
    """The puff (k: how crisp the creases between lobes are). hull=True: the same heap with much
    softer creases, for the outline hull only (it stays a hair outside the puff in every crease, so
    inflating it never folds it through the surface there)."""
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=5 if not hull else 4, radius=1.0)
    for v in bm.verts:
        u = v.co.normalized()
        p = PUFF_C + u * _puff_radius(u, k)
        if p.z < 0.12:   # a softly flattened underside
            p.z = 0.12 - (0.12 - p.z) * 0.5
        v.co = p
    _outward(bm)
    if hull:
        pc = K.Piece(K._bm_to_mesh(bm, "puff_hull"), K.OUTLINE, True, True, "puff_hull")
    else:
        bm.normal_update()
        cuts = (-0.6, -0.15, 0.5)
        nz = {v: v.normal.z for v in bm.verts}
        _iso_cut(bm, nz, cuts)
        pal = [tone(PUFF_COL, sum(nz[v] for v in f.verts) / len(f.verts), cuts) for f in bm.faces]
        pc = K.Piece(K._bm_to_mesh(bm, "puff"), pal, False, True, "puff")
    return pc


def build_puff():
    _colours()
    puff, hull = _puff(), _puff(4.6, hull=True)
    low = min(v.co.z for v in puff.mesh.vertices)   # rest the underside on z = 0
    for pc in (puff, hull):
        pc.mesh.transform(Matrix.Translation((0, 0, -low)))
    body, outline = K.finish([puff], PUFF, outline_width=0.06, outline_only=[hull])
    no_bounce(outline)
    return [body, outline] + K.markers(PUFF)


BUILDERS = {BOTTLE: build_bottle, PUFF: build_puff}
