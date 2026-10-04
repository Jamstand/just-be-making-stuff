"""
items/staticballoon.py - the StaticBalloon item (ReplicatedStorage.ItemMeshes.StaticBalloon, and its
max-level StaticBalloon_Gold): a red party balloon on a curly string, rubbed full of static. See
items/__init__.py for the conventions.

The balloon is one round party balloon (a ball a touch fuller at the top, narrowing to the neck), its
tones cut along iso-lines of the surface normal, with a bold curved highlight, a glint and a dot on
the upper left (the keyframe's light). On the front and the back (the owner sees the back of what
they hold) a die-cut sticker: a white backing round a yellow lightning bolt with an ink rim, with
little white static sparks and "+" charge signs round it. Under it the tied neck: a flared collar,
a rolled lip and a chunky knot. The string curls down from the knot in shrinking loops to a short
straight end, where the hand holds it: a thin curly string, never a rod; it gets its own thin ink
hull (the item's outline width would turn a thin string into a thick black cord).

StaticBalloon_Gold: the same shape, skeleton and markers in polished gold (the bake paints it as
metal): a ruby bolt on a white-gold sticker, twinkles and glitter flecks instead of the sparks, a
faceted ruby on the knot and a gold string.

1 unit = 1 stud: the balloon ~1.65 tall and ~1.5 wide, the string ~2.3 long. Origin = the floor
under the string's end; `_Grip` = the string's end (the hand), the balloon floats above it.

The skeleton (`rig`): `Root` at the grip (unweighted), `String1` -> `String2` -> `String3` up the
string (each from its head up to the next; String3 ends at the knot), `Balloon` (child of String3)
from the knot up through the balloon's middle to its top. Every bone points up (head -> tail =
local +Y = model up, local +Z = the front (-Y), local +X = model +X). The string is weighted along its
height (two bones blended round each joint, so it bends as a smooth curve; String3 hands over to
Balloon just under the knot); the balloon, the knot and everything on them ride Balloon rigidly.
So turning String1..3 about their local X / Z sways the string, and turning Balloon about its head
(the knot) bobs and tips the balloon. `POSES` holds preview.py's test poses.

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
from items import movekit
from props.slippers import _iso_cut, _outward

NAME = "StaticBalloon"

# texture classes: shiny rubber reads best with the plastic pattern (smooth, a painted highlight);
# the golden balloon is polished metal with glass gems
MATERIALS = {"staticballoon_red": "plastic", "staticballoon_knot": "rubber", "staticballoon_sticker": "paper",
             "staticballoon_string": "rope", "staticballoon_gold": "metal", "staticballoon_gold_sticker": "paper",
             "staticballoon_gold_gem": "glass", "staticballoon_gold_string": "rope",
             "staticballoon_gold_shine": "decal", "staticballoon_gold_glitter": "decal"}


def _colours(gold=False):
    """Registers this item's palette colours and returns them. Called by build(), not at import:
    build_all.py imports every item module before it builds the socks, so colours registered at
    import would take palette cells ahead of the socks' (items must come last, see items/__init__.py)."""
    if not gold:
        return dict(
            body=(hexcol("staticballoon_red_light", "#FF6B67"), hexcol("staticballoon_red", "#EE3340"),
                  hexcol("staticballoon_red_dark", "#B81E33")),
            knot=(hexcol("staticballoon_knot", "#D52638"), hexcol("staticballoon_knot_dark", "#A31A30")),
            gloss=hexcol("staticballoon_gloss", "#FFF4F2"),
            sticker=(hexcol("staticballoon_sticker", "#FFFFFF"), hexcol("staticballoon_sticker_shade", "#E8E4F2")),
            ink=hexcol("staticballoon_sticker_ink", "#3A1830"),
            bolt=(hexcol("staticballoon_bolt_light", "#FFE45C"), hexcol("staticballoon_bolt", "#FFC21F"),
                  hexcol("staticballoon_bolt_dark", "#F59A12")),
            spark=hexcol("staticballoon_spark", "#FFF6E8"),
            string=hexcol("staticballoon_string", "#F1EEF8"))
    G = movekit.gold("staticballoon")
    return dict(
        body=(G.light, G.base, G.dark, G.deep), knot=(G.dark, G.deep), gloss=G.shine,
        sticker=(hexcol("staticballoon_gold_sticker", "#FFF8E2"),
                 hexcol("staticballoon_gold_sticker_shade", "#F1E2B8")),
        ink=hexcol("staticballoon_gold_ink", "#5A2410"),
        bolt=movekit.gem_colours("staticballoon", "ruby", "#FF7A8A", "#E81E3C", "#A50E2A"),
        spark=G.shine, glitter=G.glitter,
        string=hexcol("staticballoon_gold_string", "#FFD75A"))


OUTLINE_W = 0.04
STRING_INK = 0.014                # the string's own ink hull
STRING_R = 0.018                  # the string's thickness (thin: a string, never a rod)
TONE_CUTS = (-0.55, 0.7)          # normal z: shade / base / lit
GOLD_CUTS = (-0.62, 0.05, 0.72)   # the golden balloon: deep / dark / base / lit (polished: more contrast)
C = Vector((0.0, 0.0, 3.36))      # balloon centre
RX, RT, RB = 0.75, 0.82, 0.86     # half width, height above / below the centre
NECK = C.z - RB                   # where the knot hangs (~2.5)
STRING_TOP = NECK - 0.21          # the string's top end, inside the knot
CURL_END = 0.42                   # the curls end here, a short straight end below
GRIP = Vector((0.0, 0.0, 0.08))
BOLT_S = 1.18                     # the sticker's bolt: BOLT scaled up
# a lightning bolt (CCW, ~0.4 x 0.72), point down; the sticker here, the slippers' toe patch
BOLT = [(0.07, 0.36), (-0.2, -0.03), (-0.02, -0.03), (-0.13, -0.36), (0.21, 0.08), (0.03, 0.08), (0.17, 0.36)]
BOLT_LIT = [(0.07, 0.36), (-0.2, -0.03), (-0.09, -0.03), (0.13, 0.36)]      # the bolt's lit facet (upper left) ...
BOLT_SHADE = [(-0.13, -0.36), (0.21, 0.08), (0.12, 0.08), (-0.1, -0.24)]    # ... and its shaded one (lower right)
# the skeleton: String1..3 heads up the string (String3's tail = Balloon's head, the knot)
JOINTS = [GRIP.z, 0.86, 1.56, STRING_TOP]
BLEND = 0.22                      # half width of the blend round each string joint


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
    """Unit sphere point -> balloon surface: a round ball, a touch fuller at the top, narrowing to the neck."""
    x, y, z = q
    w = RX * (1.0 - 0.36 * max(0.0, -z) ** 1.8) * (1.0 + 0.03 * max(0.0, z))
    h = RT if z > 0 else RB
    return C + Vector((x * w, y * w, z * h))


def _balloon(P):
    cuts = TONE_CUTS if len(P["body"]) == 3 else GOLD_CUTS
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=32, v_segments=20, radius=1.0)
    for v in bm.verts:
        v.co = _shape(v.co.copy())
    _outward(bm)
    bm.normal_update()
    nz = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, nz, cuts)
    pal = [tone(P["body"], sum(nz[v] for v in f.verts) / len(f.verts), cuts) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, "balloon"), pal, True, True, "balloon")


def _knot(P):
    """The tied neck: a flared collar under the balloon, a rolled lip and a chunky squashed knot."""
    p = []
    collar = K.cylinder(P["knot"][0], 0.07, 0.15, K.M((0, 0, NECK - 0.03)), seg=12, radius2=0.15, name="neck")
    K.recolor_by(collar, lambda c, cur: P["knot"][1] if c.x > 0.03 else cur)
    p.append(collar)
    p.append(K.torus(P["knot"][1], 0.075, 0.034, K.M((0, 0, NECK - 0.1)), seg=14, mseg=6, name="lip"))
    knot = K.sphere(P["knot"][0], 1.0, K.M((0, 0, NECK - 0.165), scale=(0.125, 0.115, 0.085)), seg=12, rings=7,
                    name="knot")
    K.recolor_by(knot, lambda c, cur: P["knot"][1] if c.z < NECK - 0.18 or c.x > 0.06 else cur)
    p.append(knot)
    return p


def _string_points():
    """From the knot down: shrinking curls that sway a little, then a short straight end (the hand)."""
    pts = []
    top = STRING_TOP
    turns = 4.5
    n = 64
    for i in range(n + 1):
        t = i / n
        z = top + (CURL_END - top) * t
        r = 0.115 * math.sin(math.pi * min(1.0, t * 1.05)) ** 0.7
        a = turns * math.tau * t
        sway = 0.08 * math.sin(math.pi * t * 1.3)
        pts.append((r * math.cos(a) + sway, r * math.sin(a), z))
    pts.append((0.0, 0.0, CURL_END - 0.16))
    pts.append((0.0, 0.0, GRIP.z - 0.03))
    return pts


def _string(P):
    return K.tube(P["string"], _string_points(), radius=STRING_R, res=2, bevel_res=0, outline=False, name="string")


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


def _gloss(P, bvh):
    """A bold curved highlight streak, a glint and a dot on the upper left front, following the outline."""
    d = Vector((-0.45, -0.66, 0.6)).normalized()
    side = Vector((0, 0, 1)).cross(d).normalized()
    up = d.cross(side)
    o = C + d * 0.2
    return [decal(bvh, _bean(0.29, 0.075, 0.05, 0.55, 0.0, 0.03), o, side, up, -d, 0.006, P["gloss"], "gloss",
                  step=0.045),
            decal(bvh, _bean(0.05, 0.04, 0.0, 0.0, 0.24, -0.15, 10), o, side, up, -d, 0.006, P["gloss"], "glint",
                  step=0.05),
            decal(bvh, movekit.circle(0.024, 8, 0.31, -0.07), o, side, up, -d, 0.006, P["gloss"], "glint", step=0.05)]


def _hull2d(poly):
    """Convex hull (CCW) of 2D points (monotone chain)."""
    pts = sorted(set((round(x, 6), round(y, 6)) for x, y in poly))

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, hi = [], []
    for q in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], q) <= 0:
            lo.pop()
        lo.append(q)
    for q in reversed(pts):
        while len(hi) >= 2 and cross(hi[-2], hi[-1], q) <= 0:
            hi.pop()
        hi.append(q)
    return lo[:-1] + hi[:-1]


def _round_offset(poly, d, arc=0.35):
    """A die-cut sticker's backing: the polygon's convex hull grown by exactly d all round, every
    corner a round arc (convex, so it never folds over itself); CCW."""
    hull = [Vector(p) for p in _hull2d(poly)]
    n = len(hull)
    out = []
    for i in range(n):
        a, b, c = hull[i - 1], hull[i], hull[(i + 1) % n]
        e1, e2 = (b - a).normalized(), (c - b).normalized()
        a1 = math.atan2(-e1.x, e1.y)            # outward normals of the two edges (CCW polygon)
        a2 = math.atan2(-e2.x, e2.y)
        while a2 < a1:
            a2 += math.tau
        k = max(1, int(math.ceil((a2 - a1) / arc)))
        for j in range(k + 1):
            t = a1 + (a2 - a1) * j / k
            out.append((b.x + d * math.cos(t), b.y + d * math.sin(t)))
    return out


def _zigzag(cx, cy, s, rot):
    """A little static spark: a three-stroke zigzag (CCW), size s, turned rot."""
    pts = [(-0.5, 0.5), (0.2, 0.14), (-0.04, 0.0), (0.5, -0.5), (-0.2, -0.12), (0.06, 0.0)]
    cr, sr = math.cos(rot), math.sin(rot)
    return [(cx + s * (x * cr - y * sr), cy + s * (x * sr + y * cr)) for x, y in pts]


def _plus(cx, cy, s, w=0.32):
    """A "+" charge sign (CCW), arm length s, arm width w * s."""
    h, a = s * 0.5, s * w * 0.5
    return [(cx + x, cy + y) for x, y in ((a, -h), (a, -a), (h, -a), (h, a), (a, a), (a, h), (-a, h), (-a, a),
                                          (-h, a), (-h, -a), (-a, -a), (-a, -h))]


def _stickers(P, bvh, gold):
    out = []
    bolt = [(x * BOLT_S, y * BOLT_S) for x, y in BOLT]
    backing = _round_offset(bolt, 0.085)
    rim = offset_poly(bolt, 0.03)
    for face in (-1, 1):   # front (-Y) and back (+Y)
        along = Vector((0, -face, 0))        # cast from outside toward the balloon
        du = Vector((-face, 0, 0))           # the sticker reads the same way from both sides
        dv = Vector((0, 0, 1))
        o = C + Vector((0, 0, 0.04))
        out.append(decal(bvh, backing, o, du, dv, along, 0.004,
                         lambda q, n: P["sticker"][1] if n.z < -0.3 else P["sticker"][0], "sticker", step=0.045))
        out.append(decal(bvh, rim, o, du, dv, along, 0.008, P["ink"], "sticker_ink", step=0.045))
        out.append(decal(bvh, bolt, o, du, dv, along, 0.012, P["bolt"][1], "bolt", step=0.045))
        for facet, col in ((BOLT_LIT, P["bolt"][0]), (BOLT_SHADE, P["bolt"][2])):   # lit / shaded facets
            f = offset_poly([(x * BOLT_S, y * BOLT_S) for x, y in facet], -0.014, miter=1.6)
            out.append(decal(bvh, f, o, du, dv, along, 0.016, col, "bolt", step=0.03))
        # static round the sticker: sparks and "+" signs (gold: twinkles and glitter flecks)
        if gold:
            marks = [movekit.sparkle(0.1, 0.24, -0.47, 0.3), movekit.sparkle(0.07, 0.24, 0.45, 0.42),
                     movekit.sparkle(0.085, 0.24, 0.5, -0.28), movekit.sparkle(0.06, 0.24, -0.42, -0.4)]
            flecks = [movekit.circle(0.022, 6, x, y) for x, y in ((-0.3, 0.55), (0.24, 0.6), (0.6, 0.08),
                                                                     (-0.58, 0.02), (-0.2, -0.62), (0.3, -0.55))]
            for m in marks:
                out.append(decal(bvh, m, o, du, dv, along, 0.006, P["spark"], "spark", step=0.06))
            for m in flecks:
                out.append(decal(bvh, m, o, du, dv, along, 0.006, P["glitter"], "glitter", step=0.08))
        else:
            for m in (_zigzag(-0.52, 0.22, 0.24, 0.35), _zigzag(0.52, -0.2, 0.22, 0.25),
                      _zigzag(0.45, 0.46, 0.17, -0.2)):
                out.append(decal(bvh, m, o, du, dv, along, 0.006, P["spark"], "spark", step=0.06))
            for m in (_plus(-0.44, -0.34, 0.12), _plus(0.27, 0.6, 0.1), _plus(-0.22, 0.62, 0.08)):
                out.append(decal(bvh, m, o, du, dv, along, 0.006, P["spark"], "spark", step=0.06))
    return out


def _ruby(P):
    """Gold only: a faceted ruby on the front of the knot."""
    return [movekit.gem(P["bolt"], (0.0, -0.105, NECK - 0.165), (0, -1, 0.25), 0.055, name="gem")]


def build(gold=False):
    name = NAME + ("_Gold" if gold else "")
    P = _colours(gold)
    balloon = _balloon(P)
    bvh = bvh_of([balloon])
    strings = [_string(P)]
    for s in strings:
        s.rig = "string"
    p = [balloon] + _knot(P) + _gloss(P, bvh) + _stickers(P, bvh, gold) + strings + (_ruby(P) if gold else [])
    body, outline = K.finish(p, name, outline_width=OUTLINE_W)
    thin_hull(outline, [_string(P)], STRING_INK)
    no_bounce(outline)
    return [body, outline] + K.markers(name) + [items.grip(name, GRIP)]


BUILDERS = {NAME: build, NAME + "_Gold": lambda: build(True)}


# ---------------------------------------------------------------- skeleton
def _string_weights(z):
    """String1..3 along the string's height, two bones blended round each joint."""
    w = {"String1": 1.0}
    for k in (1, 2):
        J = JOINTS[k]
        if z >= J - BLEND:
            t = movekit.smooth(J - BLEND, J + BLEND, z)
            w = {f"String{k}": 1.0 - t, f"String{k + 1}": t}
    top = STRING_TOP                       # String3 hands over to the balloon just under the knot
    if z > top - 0.16:
        w = movekit.mix(w, {"Balloon": 1.0}, movekit.smooth(top - 0.16, top, z))
    return w


def _sway_x(z):
    """x of the string's middle at height z (the curls sway a little)."""
    if z <= CURL_END:
        return 0.0
    t = (STRING_TOP - z) / (STRING_TOP - CURL_END)
    return 0.08 * math.sin(math.pi * t * 1.3)


def rig(name, objs):
    """`<Name>_Rig`: Root at the grip + String1..3 up the string + Balloon (child of String3)."""
    heads = JOINTS
    bones = {"Root": movekit.bone("Root", None, GRIP, GRIP + Vector((0, 0, 0.3)), "root")}
    for k in range(3):
        a, b = heads[k], heads[k + 1]
        bones[f"String{k + 1}"] = movekit.bone(f"String{k + 1}", "Root" if k == 0 else f"String{k}",
                                               (_sway_x(a), 0, a), (_sway_x(b), 0, b), "string")
    bones["Balloon"] = movekit.bone("Balloon", "String3", (0, 0, STRING_TOP), (0, 0, C.z + RT), "balloon")

    def weigh(piece, tag, co):
        if tag == "string" or piece is None:
            return _string_weights(co.z)
        return {"Balloon": 1.0}
    return movekit.skin(name, objs, bones, weigh)


# test poses for preview.py --pose (rigging.apply_pose: world axes, degrees)
POSES = {
    "rest": {},
    # the string swaying forward / sideways (each joint a little more), the balloon tipping with it
    "sway": {"String1": [((1, 0, 0), 10)], "String2": [((1, 0, 0), 14)], "String3": [((1, 0, 0), 16)],
             "Balloon": [((1, 0, 0), -12)]},
    "side": {"String1": [((0, 1, 0), -12)], "String2": [((0, 1, 0), 16)], "String3": [((0, 1, 0), 18)],
             "Balloon": [((0, 1, 0), -20)]},
    # charging: the balloon bobs and tips about the knot
    "charge": {"String3": [((1, 0, 0), -10)], "Balloon": [((1, 0, 0), 22), ((0, 1, 0), 10)]},
    # the limits: 30 degrees at every string joint
    "whip": {"String1": [((1, 0, 0), 30)], "String2": [((1, 0, 0), -30)], "String3": [((1, 0, 0), 30)],
             "Balloon": [((1, 0, 0), -25)]},
}
