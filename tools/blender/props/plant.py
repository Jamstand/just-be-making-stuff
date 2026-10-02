"""
props/plant.py - the PottedPlant prop (ReplicatedStorage.MapMeshes.PottedPlant): a tall fiddle-leaf
fig in a round terracotta pot painted with cream polka dots, standing on a matching saucer. See
props/__init__.py for the conventions every prop follows (this module's NAME is "PottedPlant").

No concept art shows it, so it is designed to sit in docs/concept/bedroom_keyframe.png: chunky soft
toy shapes, flat 2-3 tone colours, thick ink lines. The pot is a lathe (a flared body, a fat rolled
rim, dark soil inside), lit / base / shaded by the profile's slope; the dots are thin curved patches
lying on the body. Three woody stems rise from the soil, gently curved, the tallest nearly to the
ceiling of the fit box; big glossy fiddle-shaped leaves (widest near the rounded tip, a soft waist
low down) grow from them in a spiral, each a chunky cupped leaf bent along a drooping arc: top side
in two greens (a lit highlight where it faces up, base green elsewhere) with a pale midrib cut in as
a crisp line, the underside in a darker green.

Units: 1 unit = 10 studs. Map fits the model uniformly into 90 x 170 x 90 studs (W x H x D); the
model is about 8.6 x 17.1 x 7.7 units (W x H x D). Origin = floor centre (under the saucer), front
faces -Y.
"""
import math
import random
import bmesh
from mathutils import Vector
import sockkit as K
from sockkit import hexcol

NAME = "PottedPlant"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"plant_pot": "ceramic", "plant_rim": "ceramic", "plant_dot": "ceramic", "plant_soil": "soil",
             "plant_stem": "wood"}

POT = (hexcol("plant_pot_light", "#F2965F"), hexcol("plant_pot", "#DB6C3F"), hexcol("plant_pot_shade", "#B24E2E"))
RIM = (hexcol("plant_rim_light", "#FBB37C"), hexcol("plant_rim", "#E8814F"), hexcol("plant_rim_shade", "#BF5A34"))
DOT = hexcol("plant_dot", "#FFF0D2")
SOIL = (hexcol("plant_soil_light", "#7A5038"), hexcol("plant_soil", "#5A3626"))
STEM = (hexcol("plant_stem_light", "#A8774A"), hexcol("plant_stem", "#7E5434"))
LEAF = (hexcol("plant_leaf_light", "#A8E86C"),   # top side facing up: the glossy highlight
        hexcol("plant_leaf", "#62C752"),         # top side
        hexcol("plant_leaf_under", "#46A656"))   # underside
VEIN = hexcol("plant_leaf_vein", "#C2E886")

OUTLINE_W = 0.15      # ~2.3% of the pot's width, ~0.9% of the plant's height
LATHE_SEG = 28


# ---------------------------------------------------------------- helpers
def _iso_cut(bm, vals, cuts):
    """Splits the faces of `bm` along the iso-lines vals == c for every c in `cuts` (vals: vert ->
    float, extended to the new verts), so a colour step drawn at c is a clean curve instead of a
    stair of whole faces. The surface itself is unchanged (new verts sit on existing edges)."""
    for c in cuts:
        for v in bm.verts:
            if abs(vals[v] - c) < 1e-5:
                vals[v] = c + 1e-5
        new = set()
        for e in list(bm.edges):
            a, b = e.verts
            va, vb = vals[a], vals[b]
            if (va - c) * (vb - c) < 0:
                _, nv = bmesh.utils.edge_split(e, a, (c - va) / (vb - va))
                vals[nv] = c
                new.add(nv)
        for f in list(bm.faces):
            vs = [v for v in f.verts if v in new]
            if len(vs) == 2 and bm.edges.get(vs) is None:
                bmesh.utils.face_split(f, vs[0], vs[1])
            elif len(vs) == 4:  # saddle: two separate crossings
                for x, y in ((vs[0], vs[1]), (vs[2], vs[3])):
                    for g in set(x.link_faces) & set(y.link_faces):
                        if bm.edges.get((x, y)) is None:
                            bmesh.utils.face_split(g, x, y)
                            break


def _outward(bm):
    """Turns a closed mesh's faces outward (by its signed volume)."""
    vol = 0.0
    for f in bm.faces:
        vs = [v.co for v in f.verts]
        for i in range(1, len(vs) - 1):
            vol += vs[0].dot(vs[i].cross(vs[i + 1]))
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])


def _lathe(profile, pal, name, seg=LATHE_SEG, outline=True):
    """Closed solid of revolution about Z: `profile` = [(r, z)] from the axis round to the axis.
    pal(profile segment index, face normal) -> palette index."""
    bm = bmesh.new()
    rings = []
    for r, z in profile:
        if r < 1e-6:
            rings.append([bm.verts.new((0.0, 0.0, z))])
        else:
            rings.append([bm.verts.new((r * math.cos(a), r * math.sin(a), z))
                          for a in (j / seg * math.tau for j in range(seg))])
    seg_of = []
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        for j in range(seg):
            k = (j + 1) % seg
            if len(a) == 1:
                bm.faces.new((a[0], b[j], b[k]))
            elif len(b) == 1:
                bm.faces.new((a[j], b[0], a[k]))
            else:
                bm.faces.new((a[j], b[j], b[k], a[k]))
            seg_of.append(i)
    _outward(bm)
    bm.normal_update()
    fp = [pal(seg_of[f.index], f.normal) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, name), fp, outline, True, name)


def _tone3(cols, nz, up=0.55, down=-0.35):
    return cols[0] if nz > up else (cols[2] if nz < down else cols[1])


# ---------------------------------------------------------------- the pot
SAUCER = [(0.0, 0.0), (2.75, 0.0), (3.15, 0.25), (3.32, 0.52), (3.22, 0.62), (3.05, 0.45), (2.75, 0.3), (0.0, 0.3)]
POT_R0, POT_R1, POT_Z0, POT_Z1 = 2.05, 2.72, 0.3, 4.1   # body: bottom / top radius and height
POT_PROFILE = [(0.0, POT_Z0), (1.85, POT_Z0), (2.0, POT_Z0 + 0.06), (POT_R0, POT_Z0 + 0.25),
               (POT_R1, POT_Z1),
               # the rolled rim
               (3.02, POT_Z1 + 0.03), (3.16, POT_Z1 + 0.16), (3.2, POT_Z1 + 0.45), (3.2, POT_Z1 + 0.85),
               (3.14, POT_Z1 + 1.0), (2.98, POT_Z1 + 1.05), (2.8, POT_Z1 + 1.02), (2.74, POT_Z1 + 0.9),
               # inner wall down to the soil, then the soil mound
               (2.7, POT_Z1 + 0.62), (2.2, POT_Z1 + 0.66), (1.0, POT_Z1 + 0.78), (0.0, POT_Z1 + 0.82)]
RIM_SEGS = range(4, 12)
SOIL_SEGS = range(13, 16)


def _pot_pal(i, n):
    if i in SOIL_SEGS:
        return SOIL[0] if n.z > 0.97 else SOIL[1]
    if i in RIM_SEGS or i == 12:
        return _tone3(RIM, n.z)
    return _tone3(POT, n.z)


def _pot_r(z):
    t = (z - (POT_Z0 + 0.25)) / (POT_Z1 - POT_Z0 - 0.25)
    return POT_R0 + (POT_R1 - POT_R0) * t


def _dot(a0, z0, rad, seg=10):
    """A cream polka dot lying on the pot's flared body: a small fan of triangles bent round it."""
    bm = bmesh.new()
    slope = (POT_R1 - POT_R0) / (POT_Z1 - POT_Z0 - 0.25)
    cs = 1 / math.sqrt(1 + slope * slope)   # the side's length per unit height

    def at(dx, dz):
        z = z0 + dz * cs
        r = _pot_r(z) + 0.035
        a = a0 + dx / r
        return bm.verts.new((r * math.cos(a), r * math.sin(a), z))
    c = at(0, 0)
    ring = [at(rad * math.cos(t), rad * math.sin(t)) for t in (j / seg * math.tau for j in range(seg))]
    for j in range(seg):
        bm.faces.new((c, ring[j], ring[(j + 1) % seg]))
    bm.normal_update()
    if sum(f.normal.dot(Vector((math.cos(a0), math.sin(a0), 0))) for f in bm.faces) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    return K.Piece(K._bm_to_mesh(bm, "dot"), DOT, outline=False, smooth=True, name="dot")


def _pot():
    out = [_lathe(SAUCER, lambda i, n: _tone3(RIM, n.z, 0.7), "saucer"),
           _lathe(POT_PROFILE, _pot_pal, "pot")]
    for row, (z, n, off, r) in enumerate(((1.35, 9, 0.0, 0.34), (2.9, 9, 0.5, 0.34))):
        for k in range(n):
            out.append(_dot(math.tau * (k + off) / n - math.pi / 2 + 0.17, z, r))
    return out


# ---------------------------------------------------------------- stems and leaves
def _catmull(ctrl, t):
    """Point on a uniform Catmull-Rom through ctrl at t in [0, 1]."""
    n = len(ctrl) - 1
    x = min(max(t, 0.0), 1.0) * n
    i = min(int(x), n - 1)
    u = x - i
    P = [Vector(ctrl[max(0, min(n, k))]) for k in (i - 1, i, i + 1, i + 2)]
    if i == 0:
        P[0] = P[1] * 2 - P[2]
    if i + 2 > n:
        P[3] = P[2] * 2 - P[1]
    return 0.5 * ((P[1] * 2) + (P[2] - P[0]) * u + (P[0] * 2 - P[1] * 5 + P[2] * 4 - P[3]) * u * u
                  + (P[1] * 3 - P[0] - P[2] * 3 + P[3]) * u * u * u)


SOIL_Z = POT_Z1 + 0.72
# stems: control points (units) and base radius
STEMS = [
    ([(0.25, 0.15, SOIL_Z - 0.3), (0.35, 0.1, 7.0), (-0.1, 0.25, 10.2), (-0.35, 0.3, 12.9), (-0.2, 0.2, 14.8)], 0.24),
    ([(-0.35, -0.25, SOIL_Z - 0.3), (-0.6, -0.4, 6.6), (-1.35, -0.55, 9.0), (-1.95, -0.6, 11.2)], 0.19),
    ([(0.1, 0.45, SOIL_Z - 0.3), (0.55, 0.85, 6.4), (1.45, 1.2, 8.3), (2.0, 1.25, 9.6)], 0.17),
]


def _stem(ctrl, r0):
    pts = [tuple(_catmull(ctrl, i / 6)) for i in range(7)]
    radii = [1.0 - 0.45 * i / 6 for i in range(7)]
    p = K.tube(STEM[1], pts, radius=r0, radii=radii, res=2, bevel_res=1, name="stem")
    p.face_pal = [STEM[0] if f.normal.z > 0.5 else STEM[1] for f in p.mesh.polygons]
    return p


def _leaf_width(t):
    """Fiddle-leaf outline: half width (fraction of the max) at t (0 = base, 1 = tip)."""
    t = min(max(t, 0.0), 1.0)
    circ = (2 * math.sqrt(t * (1 - t))) ** 0.7
    return circ * (0.45 + 0.7 * t) * (1 - 0.13 * math.exp(-((t - 0.34) / 0.1) ** 2))


def _leaf(base, out_dir, length, rise, droop, roll=0.0, seg=8, rings=10):
    """One chunky fiddle leaf from `base`, pointing along the horizontal `out_dir`, its axis starting
    `rise` (radians) above horizontal and bending down by `droop` toward the tip; cupped (edges
    curled up), widest near the rounded tip. Top: highlight / base green and a pale midrib line;
    underside darker."""
    out_dir = Vector((out_dir.x, out_dir.y, 0.0)).normalized()
    side0 = Vector((0, 0, 1)).cross(out_dir).normalized()
    width = length * 0.42
    thick = 0.075 + 0.02 * length

    def axis(t):
        a = rise - droop * t * t
        # the axis as a curve: integrate the turning direction
        n = 12
        p = Vector(base)
        for k in range(int(n * t)):
            ak = rise - droop * (k / n) ** 2
            p += (out_dir * math.cos(ak) + Vector((0, 0, math.sin(ak)))) * (length / n)
        rem = n * t - int(n * t)
        p += (out_dir * math.cos(a) + Vector((0, 0, math.sin(a)))) * (length / n) * rem
        tan = (out_dir * math.cos(a) + Vector((0, 0, math.sin(a)))).normalized()
        return p, tan

    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
    un_of = {}
    top_of = {}
    for v in bm.verts:
        x, y, z = v.co   # pole on z -> along the leaf; x across; y through the thickness
        t = (z + 1) / 2
        s = math.sqrt(max(1e-9, 1 - z * z))
        un, wn = x / s, y / s
        p, tan = axis(t)
        side = (side0 * math.cos(roll) + tan.cross(side0).normalized() * math.sin(roll)).normalized()
        nrm = side.cross(tan).normalized()
        if nrm.z < 0:
            nrm = -nrm
        w = width * _leaf_width(t)
        cup = 0.16 * w * un * un
        v.co = p + side * (un * w) + nrm * (wn * thick * (0.3 + 0.7 * (1 - un * un)) + cup)
        un_of[v] = un if wn > 0 else 9.0
        top_of[v] = wn
    _outward(bm)
    bm.normal_update()
    # the midrib: a narrow strip down the middle of the top side
    _iso_cut(bm, un_of, (-0.07, 0.07))
    pal = []
    for f in bm.faces:
        u = sum(un_of[v] for v in f.verts) / len(f.verts)
        top = sum(top_of.get(v, 1.0) for v in f.verts if v in top_of) / max(1, sum(1 for v in f.verts if v in top_of))
        fz = f.normal.z
        if abs(u) < 0.07 and top > 0.3:
            pal.append(VEIN)
        elif fz < -0.05 or top < -0.2:
            pal.append(LEAF[2])
        elif fz > 0.62:
            pal.append(LEAF[0])
        else:
            pal.append(LEAF[1])
    return K.Piece(K._bm_to_mesh(bm, "leaf"), pal, True, True, "leaf")


def _foliage():
    out = []
    rnd = random.Random(11)
    golden = math.radians(137.5)
    # (stem index, from t, to t, leaf count, length range, first azimuth)
    plan = [(0, 0.3, 1.0, 11, (2.8, 3.8), 0.9), (1, 0.4, 1.0, 6, (2.7, 3.4), 2.4), (2, 0.38, 1.0, 4, (2.7, 3.3), 4.1)]
    for si, t0, t1, n, (l0, l1), az0 in plan:
        ctrl = STEMS[si][0]
        for k in range(n):
            u = k / (n - 1)
            t = t0 + (t1 - t0) * u
            p = _catmull(ctrl, min(t, 0.985))
            az = az0 + golden * k
            d = Vector((math.cos(az), math.sin(az), 0))
            # lower leaves reach out and droop, upper ones stand up; the last ones crown the stem
            length = l0 + (l1 - l0) * math.sin(math.pi * min(1.0, 0.25 + 0.9 * u)) + rnd.uniform(-0.15, 0.15)
            rise = math.radians(8 + 58 * u ** 1.8) + rnd.uniform(-0.08, 0.08)
            droop = math.radians(58 - 30 * u) + rnd.uniform(-0.1, 0.1)
            out.append(_leaf(p - d * 0.05, d, length, rise, droop, roll=rnd.uniform(-0.25, 0.25)))
    return out


# ---------------------------------------------------------------- build
def _no_bounce(outline):
    """Preview only (Cycles ray flags, not exported): the inverted hull must not block bounce light."""
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission"):
        if hasattr(outline, attr):
            setattr(outline, attr, False)


def build():
    p = _pot()
    p += [_stem(c, r) for c, r in STEMS]
    p += _foliage()
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    _no_bounce(outline)
    return [body, outline] + K.markers(NAME)
