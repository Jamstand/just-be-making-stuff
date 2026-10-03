"""
items/staticballoon.py - the StaticBalloon item (ReplicatedStorage.ItemMeshes.StaticBalloon): a red
party balloon on a curly string, rubbed full of static. See items/__init__.py for the conventions.

The balloon is one smooth egg (fuller at the top, narrowing to the neck), its tones cut along
iso-lines of the surface normal, with a curved glossy highlight and a small glint on the upper left
(the keyframe's light), a white lightning-bolt sticker with an ink rim on the front and the back
(the owner sees the back of what they hold), and the tied knot under it. The string curls down from
the knot in shrinking loops to a short straight end, where the hand holds it; it gets its own
thin ink hull (the item's outline width would turn a thin string into a thick black cord).

1 unit = 1 stud: the balloon ~1.6 tall and ~1.3 wide, the string ~2.5 long. Origin = the floor
under the string's end; `_Grip` = the string's end (the hand), the balloon floats above it.

Shared helpers the other item modules import (items/ has no common module): `decal` (a flat 2D
shape projected onto a surface, triangulated finely enough to follow its curve), `offset_poly` (a 2D
outline grown / shrunk), `bvh_of` (pieces -> one BVH to cast decals on), `thin_hull` (an extra ink
hull of its own width for thin parts), `tone` (light -> dark tone by normal z), `no_bounce` (the
preview-only hull ray settings) and the `BOLT` outline.
"""
import math
import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import delaunay_2d_cdt
import sockkit as K
from sockkit import hexcol
import items
from props.slippers import _iso_cut, _outward

NAME = "StaticBalloon"

# texture classes: shiny rubber reads best with the plastic pattern (smooth, a painted highlight)
MATERIALS = {"staticballoon_red": "plastic", "staticballoon_knot": "rubber", "staticballoon_sticker": "paper",
             "staticballoon_string": "rope"}


def _colours():
    """Registers this item's palette colours. Called by build(), not at import: build_all.py imports
    every item module before it builds the socks, so colours registered at import would take palette
    cells ahead of the socks' (items must come last, see items/__init__.py)."""
    global RED, KNOT, GLOSS, STICKER, STICKER_INK, STRING
    RED = (hexcol("staticballoon_red_light", "#FF6B67"), hexcol("staticballoon_red", "#EE3340"),
           hexcol("staticballoon_red_dark", "#B81E33"))
    KNOT = (hexcol("staticballoon_knot", "#D52638"), hexcol("staticballoon_knot_dark", "#A31A30"))
    GLOSS = hexcol("staticballoon_gloss", "#FFF4F2")
    STICKER = (hexcol("staticballoon_sticker", "#FFFFFF"), hexcol("staticballoon_sticker_shade", "#E8E4F2"))
    STICKER_INK = hexcol("staticballoon_sticker_ink", "#3A1830")
    STRING = hexcol("staticballoon_string", "#F1EEF8")


OUTLINE_W = 0.04
STRING_INK = 0.014                # the string's own ink hull
TONE_CUTS = (-0.55, 0.7)          # normal z: shade / base / lit
C = Vector((0.0, 0.0, 3.32))      # balloon centre
RX, RT, RB = 0.66, 0.78, 0.84     # half width, height above / below the centre
NECK = C.z - RB                   # where the knot hangs (~2.48)
GRIP = Vector((0.0, 0.0, 0.08))
# a lightning bolt (CCW, ~0.4 x 0.72), point down; the sticker here, the slippers' toe patch
BOLT = [(0.07, 0.36), (-0.2, -0.03), (-0.02, -0.03), (-0.13, -0.36), (0.21, 0.08), (0.03, 0.08), (0.17, 0.36)]


# ---------------------------------------------------------------- shared helpers (other items import these)
def densify(poly, step):
    """A closed 2D polygon with extra points so no edge is longer than `step`."""
    out = []
    n = len(poly)
    for i in range(n):
        a, b = Vector(poly[i]), Vector(poly[(i + 1) % n])
        k = max(1, int(math.ceil((b - a).length / step)))
        for j in range(k):
            out.append(a.lerp(b, j / k))
    return out


def _inside(poly, q):
    c = False
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        if (a[1] > q[1]) != (b[1] > q[1]):
            x = a[0] + (q[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
            if q[0] < x:
                c = not c
    return c


def _seg_dist(q, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (q - a).dot(ab) / max(ab.length_squared, 1e-12)))
    return (q - (a + ab * t)).length


def offset_poly(poly, d, miter=2.85):
    """The closed 2D polygon (CCW) grown outward by d (negative: shrunk), mitred corners (a corner
    moves at most `miter` x d)."""
    pts = [Vector(p) for p in poly]
    n = len(pts)
    out = []
    for i in range(n):
        a, b, c = pts[i - 1], pts[i], pts[(i + 1) % n]
        e1 = (b - a).normalized()
        e2 = (c - b).normalized()
        n1 = Vector((e1.y, -e1.x))   # outward normal of a CCW polygon
        n2 = Vector((e2.y, -e2.x))
        m = (n1 + n2)
        if m.length < 1e-6:
            m = n1
        m.normalize()
        k = 1.0 / max(1.0 / miter, m.dot(n1))
        out.append(tuple(b + m * d * k))
    return out


def decal(bvh, poly, origin, du, dv, along, lift, pal, name="decal", step=0.035, outline=False, smooth=True):
    """A flat shape stuck on a surface: the closed 2D polygon `poly` (CCW, in units of du / dv from
    `origin`) is triangulated with interior points every `step` (so it follows the curve), then every
    vertex is cast along `along` onto the surface in `bvh` and lifted `lift` off it along the hit normal.
    `pal` = a palette index, or pal(2D point, surface normal) -> index per face."""
    du, dv, along = Vector(du), Vector(dv), Vector(along).normalized()
    origin = Vector(origin)
    ring = densify(poly, step)
    pts = [Vector(p) for p in ring]
    xs = [p.x for p in pts]
    ys = [p.y for p in pts]
    x = min(xs) + step * 0.5
    while x < max(xs):
        y = min(ys) + step * 0.5
        while y < max(ys):
            q = Vector((x, y))
            if _inside(poly, q) and min(_seg_dist(q, ring[i], ring[(i + 1) % len(ring)])
                                        for i in range(len(ring))) > step * 0.45:
                pts.append(q)
            y += step
        x += step
    res = delaunay_2d_cdt(pts, [], [list(range(len(ring)))], 1, 1e-7)
    vco, faces = res[0], res[2]
    bm = bmesh.new()
    vs = []
    for q in vco:
        o = origin + du * q.x + dv * q.y
        hit, nor, _i, _d = bvh.ray_cast(o - along * 8.0, along)
        if hit is None:
            hit, nor = o, -along
        if nor.dot(along) > 0:
            nor = -nor
        vs.append(bm.verts.new(hit + nor * lift))
    keep = []
    for f in faces:
        try:
            keep.append((bm.faces.new([vs[i] for i in f]), f))
        except ValueError:
            pass
    bm.normal_update()
    if sum(f.normal.dot(along) for f, _ in keep) > 0:   # face back out of the surface
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    bm.normal_update()
    if callable(pal):
        fp = []
        for f, idx in keep:
            c2 = sum((vco[i] for i in idx), Vector((0.0, 0.0))) / len(idx)
            fp.append(pal(c2, f.normal))
        piece = K.Piece(K._bm_to_mesh(bm, name), fp, outline, smooth, name)
    else:
        piece = K.Piece(K._bm_to_mesh(bm, name), pal, outline, smooth, name)
    return piece


def bvh_of(pieces):
    """One BVH over the meshes of several pieces (decals are cast onto it)."""
    verts, polys = [], []
    for p in pieces:
        base = len(verts)
        verts += [v.co.copy() for v in p.mesh.vertices]
        polys += [tuple(base + i for i in f.vertices) for f in p.mesh.polygons]
    return BVHTree.FromPolygons(verts, polys)


def thin_hull(outline_obj, pieces, width):
    """Appends an inverted hull `width` thick round each piece to `outline_obj` (the `_Outline` object
    K.finish made): thin parts (strings, cords) get a thin line instead of the item's full outline.
    Pass freshly built pieces (K.finish frees the meshes of the pieces it merged); they are freed here."""
    bm = bmesh.new()
    bm.from_mesh(outline_obj.data)
    uv = bm.loops.layers.uv.verify()
    u, v = K.swatch_uv(K.OUTLINE)
    for p in pieces:
        tmp = bmesh.new()
        tmp.from_mesh(p.mesh)
        tmp.normal_update()
        for vt in tmp.verts:
            vt.co += vt.normal * width
        bmesh.ops.reverse_faces(tmp, faces=tmp.faces[:])
        vmap = {vt: bm.verts.new(vt.co) for vt in tmp.verts}
        for f in tmp.faces:
            try:
                nf = bm.faces.new([vmap[vt] for vt in f.verts])
            except ValueError:
                continue
            nf.smooth = False
            for loop in nf.loops:
                loop[uv].uv = (u, v)
        tmp.free()
        bpy.data.meshes.remove(p.mesh)
    bm.to_mesh(outline_obj.data)
    bm.free()


def no_bounce(outline):
    """Preview only (Cycles ray visibility, not exported): the hull is seen by the camera but does not
    block light, the way it behaves in Roblox."""
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission", "visible_volume_scatter"):
        if hasattr(outline, attr):
            setattr(outline, attr, False)


def tone(cols, nz, cuts):
    """cols light -> dark, cuts ascending (one fewer than cols): the tone for a normal z."""
    for i, c in enumerate(reversed(cuts)):
        if nz > c:
            return cols[i]
    return cols[len(cuts)]


# ---------------------------------------------------------------- the balloon
def _shape(q):
    """Unit sphere point -> balloon surface: an egg, fuller at the top, narrowing to the neck."""
    x, y, z = q
    w = RX * (1.0 - 0.42 * max(0.0, -z) ** 1.7) * (1.0 + 0.04 * max(0.0, z))
    h = RT if z > 0 else RB
    return C + Vector((x * w, y * w, z * h))


def _balloon():
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=30, v_segments=20, radius=1.0)
    for v in bm.verts:
        v.co = _shape(v.co.copy())
    _outward(bm)
    bm.normal_update()
    nz = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, nz, TONE_CUTS)
    pal = [tone(RED, sum(nz[v] for v in f.verts) / len(f.verts), TONE_CUTS) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, "balloon"), pal, True, True, "balloon")


def _knot():
    """The tied neck: a little flared collar under the balloon and a squashed bead of a knot."""
    p = []
    p.append(K.cylinder(KNOT[0], 0.05, 0.12, K.M((0, 0, NECK - 0.02)), seg=10, radius2=0.11, name="neck"))
    p.append(K.sphere(KNOT[1], 1.0, K.M((0, 0, NECK - 0.1), scale=(0.1, 0.1, 0.07)), seg=12, rings=7, name="knot"))
    return p


def _string_points():
    """From the knot down: shrinking curls that sway a little, then a short straight end (the hand)."""
    pts = []
    top, curl_end = NECK - 0.14, 0.42
    turns = 4.5
    n = 64
    for i in range(n + 1):
        t = i / n
        z = top + (curl_end - top) * t
        r = 0.11 * math.sin(math.pi * min(1.0, t * 1.05)) ** 0.7
        a = turns * math.tau * t
        sway = 0.08 * math.sin(math.pi * t * 1.3)
        pts.append((r * math.cos(a) + sway, r * math.sin(a), z))
    pts.append((0.0, 0.0, curl_end - 0.16))
    pts.append((0.0, 0.0, GRIP.z - 0.03))
    return pts


def _string():
    return K.tube(STRING, _string_points(), radius=0.016, res=2, bevel_res=0, outline=False, name="string")


def _bean(a, b, bend, roll, cx=0.0, cy=0.0, n=20):
    """A 2D highlight shape: an ellipse (half axes a, b) bent into a soft crescent (`bend`: the ends
    curl down), turned `roll` radians, centred on (cx, cy); CCW."""
    out = []
    cr, sr = math.cos(roll), math.sin(roll)
    for j in range(n):
        t = j / n * math.tau
        u = a * math.cos(t)
        w = b * math.sin(t) - bend * (u / a) ** 2
        out.append((cx + u * cr - w * sr, cy + u * sr + w * cr))
    return out


def _gloss(bvh):
    """A curved highlight streak + a small glint on the upper left front, following the outline."""
    d = Vector((-0.45, -0.66, 0.6)).normalized()
    side = Vector((0, 0, 1)).cross(d).normalized()
    up = d.cross(side)
    o = C + d * 0.2
    streak = decal(bvh, _bean(0.25, 0.065, 0.08, 0.55, 0.0, 0.02), o, side, up, -d, 0.006, GLOSS, "gloss", step=0.04)
    glint = decal(bvh, _bean(0.04, 0.032, 0.0, 0.0, 0.2, -0.13, 10), o, side, up, -d, 0.006, GLOSS, "glint", step=0.04)
    return [streak, glint]


def _stickers(bvh):
    out = []
    for face in (-1, 1):   # front (-Y) and back (+Y)
        along = Vector((0, -face, 0))        # cast from outside toward the balloon
        du = Vector((-face, 0, 0))           # the bolt reads the same way from both sides
        o = C + Vector((0, 0, 0.02))
        ink = offset_poly(BOLT, 0.028)
        out.append(decal(bvh, ink, o, du, Vector((0, 0, 1)), along, 0.004, STICKER_INK, "sticker_ink", step=0.04))
        out.append(decal(bvh, BOLT, o, du, Vector((0, 0, 1)), along, 0.008,
                         lambda q, n: STICKER[1] if n.z < -0.25 else STICKER[0], "sticker", step=0.04))
    return out


def build():
    _colours()
    balloon = _balloon()
    bvh = bvh_of([balloon])
    p = [balloon] + _knot() + _gloss(bvh) + _stickers(bvh) + [_string()]
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    thin_hull(outline, [_string()], STRING_INK)
    no_bounce(outline)
    return [body, outline] + K.markers(NAME) + [items.grip(NAME, GRIP)]


BUILDERS = {NAME: build}
