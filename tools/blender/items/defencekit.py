"""
items/defencekit.py - shared helpers for the four "defence" items (bananapeel.py, bubbleblaster.py,
alarmduck.py, softener.py): mesh helpers, the golden versions' gems and sparkles, and the item
skeletons (bones + skin weights). Not an item module itself (it has no BUILDERS).

Mesh helpers (copies of the ones in props/ and items/staticballoon.py, kept here so these four
items don't depend on another item module): `smooth`, `tone` (light -> dark by normal z), `outward`
(turn a closed bmesh outward), `iso_cut` (split faces along iso-lines so colour steps are clean
curves), `decal` (a flat 2D shape cast onto a surface), `offset_poly`, `bvh_of`, `no_bounce`
(preview-only hull ray settings), `lathe` (a surface of revolution), `flat_poly` (a flat 2D shape laid
on a point of a surface), `ribbon` (a thin painted stripe following a surface), `star` / `circle` (2D
outlines).

Golden versions: `gem` (a small faceted, flat-shaded jewel set on a surface; three tones) and
`sparkle` (a flat four-point glitter star).

Skeletons (`armature` + `skin`): like towel.py's rig, but every bone gets an explicit roll (its local
+Z points along `z`), so every bone of a kind animates the same way. Root has no weights; every
piece carries a `rig` tag (set with `tag(piece, tag)`) that names a bone (rigid) or a weight field of
the item (`fields[tag](point) -> {bone: weight}`); the outline hull copies, vertex for vertex, the
weights of the body vertex it was inflated from (sockkit.finish records which is which), and
outline-only pieces are weighted like their tag at their own position. At most 4 bones per vertex,
normalised (rigging._finalise).
"""
import math

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import delaunay_2d_cdt

import rigging
import sockkit as K
from sockkit import hexcol


# ---------------------------------------------------------------- small maths
def smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def tone(cols, nz, cuts):
    """cols light -> dark, cuts ascending (one fewer than cols): the tone for a normal z."""
    for i, c in enumerate(reversed(cuts)):
        if nz > c:
            return cols[i]
    return cols[len(cuts)]


def mix(a, b, t):
    """Weights a * (1 - t) + b * t (dicts bone -> weight)."""
    out = {}
    for k, v in a.items():
        out[k] = out.get(k, 0.0) + v * (1.0 - t)
    for k, v in b.items():
        out[k] = out.get(k, 0.0) + v * t
    return {k: v for k, v in out.items() if v > 0.0}


# ---------------------------------------------------------------- bmesh helpers
def outward(bm):
    """Turns a closed mesh's faces outward (by its signed volume)."""
    vol = 0.0
    for f in bm.faces:
        vs = [v.co for v in f.verts]
        for i in range(1, len(vs) - 1):
            vol += vs[0].dot(vs[i].cross(vs[i + 1]))
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])


def iso_cut(bm, vals, cuts):
    """Splits the faces of `bm` along the iso-lines vals == c for every c in `cuts` (vals: vert ->
    float, extended to the new verts): a colour step drawn at c is a clean curve, not a stair."""
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


def piece(bm, pal, name, outline=True, smooth_=True, flat=None):
    """bmesh -> K.Piece (frees the bmesh); `flat`: face indices drawn flat."""
    p = K.Piece(K._bm_to_mesh(bm, name), pal, outline, smooth_, name)
    if flat:
        p.flat_faces = list(flat)
    return p


def toned(bm, cols, cuts, name, outline=True, field=None, metal=False):
    """Cuts a closed bmesh along normal-z iso-lines and colours it light -> dark (`field(v)` instead
    of the normal's z if given) -> Piece. metal=True: polished metal banding (GOLD_CUTS, metal_tone;
    cols = light, base, dark, deep)."""
    outward(bm)
    bm.normal_update()
    vals = {v: (field(v) if field else (metal_value(v.normal) if metal else v.normal.z)) for v in bm.verts}
    if metal:
        iso_cut(bm, vals, GOLD_CUTS)
        pal = [metal_tone(cols, sum(vals[v] for v in f.verts) / len(f.verts)) for f in bm.faces]
    else:
        iso_cut(bm, vals, cuts)
        pal = [tone(cols, sum(vals[v] for v in f.verts) / len(f.verts), cuts) for f in bm.faces]
    return piece(bm, pal, name, outline)


def tag(p, t):
    """Sets the piece's rig tag (a bone name or a field name of the item's rig) and returns it."""
    p.rig = t
    return p


def tag_all(pieces, t):
    for p in pieces:
        p.rig = t
    return pieces


def recolor_normals(p, fn):
    """Re-colours a piece's faces with fn(face normal, face centre) -> palette index."""
    p.face_pal = [fn(Vector(f.normal), Vector(f.center)) for f in p.mesh.polygons]
    return p


def transform(pieces, mat):
    for p in pieces:
        p.mesh.transform(mat)
    return pieces


# ---------------------------------------------------------------- 2D outlines and decals
def densify(poly, step):
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
    """The closed 2D polygon (CCW) grown outward by d (negative: shrunk), mitred corners."""
    pts = [Vector(p) for p in poly]
    n = len(pts)
    out = []
    for i in range(n):
        a, b, c = pts[i - 1], pts[i], pts[(i + 1) % n]
        e1 = (b - a).normalized()
        e2 = (c - b).normalized()
        n1 = Vector((e1.y, -e1.x))
        n2 = Vector((e2.y, -e2.x))
        m = n1 + n2
        if m.length < 1e-6:
            m = n1
        m.normalize()
        k = 1.0 / max(1.0 / miter, m.dot(n1))
        out.append(tuple(b + m * d * k))
    return out


def circle(cx, cy, r, n=14, sx=1.0, rot=0.0):
    out = []
    for i in range(n):
        a = 2 * math.pi * i / n
        x, y = r * sx * math.cos(a), r * math.sin(a)
        out.append((cx + x * math.cos(rot) - y * math.sin(rot), cy + x * math.sin(rot) + y * math.cos(rot)))
    return out


def star(cx, cy, r_out, r_in, n=5, rot=0.0):
    """A CCW star outline (n points, the first pointing up + rot)."""
    return [(cx + (r_out if i % 2 == 0 else r_in) * math.cos(math.pi / 2 + rot + math.pi * i / n),
             cy + (r_out if i % 2 == 0 else r_in) * math.sin(math.pi / 2 + rot + math.pi * i / n)) for i in range(2 * n)]


def rounded_rect(hw, hh, rc, n=5, cx=0.0, cy=0.0):
    out = []
    for (x, y, a0) in ((hw - rc, -hh + rc, -90), (hw - rc, hh - rc, 0), (-hw + rc, hh - rc, 90), (-hw + rc, -hh + rc, 180)):
        for k in range(n + 1):
            a = math.radians(a0 + 90 * k / n)
            out.append((cx + x + rc * math.cos(a), cy + y + rc * math.sin(a)))
    return out


def decal(bvh, poly, origin, du, dv, along, lift, pal, name="decal", step=0.035, outline=False, smooth_=True):
    """A flat shape stuck on a surface: the closed 2D polygon `poly` (CCW, in units of du / dv from
    `origin`) is triangulated with interior points every `step`, then every vertex is cast along
    `along` onto the surface in `bvh` and lifted `lift` off it along the hit normal. `pal` = a palette
    index, or pal(2D point, surface normal) -> index per face."""
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
    if sum(f.normal.dot(along) for f, _ in keep) > 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    bm.normal_update()
    if callable(pal):
        fp = []
        for f, idx in keep:
            c2 = sum((vco[i] for i in idx), Vector((0.0, 0.0))) / len(idx)
            fp.append(pal(c2, f.normal))
        return K.Piece(K._bm_to_mesh(bm, name), fp, outline, smooth_, name)
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline, smooth_, name)


def bvh_of(pieces):
    verts, polys = [], []
    for p in pieces:
        base = len(verts)
        verts += [v.co.copy() for v in p.mesh.vertices]
        polys += [tuple(base + i for i in f.vertices) for f in p.mesh.polygons]
    return BVHTree.FromPolygons(verts, polys)


def no_bounce(outline):
    """Preview only (Cycles ray visibility, not exported): the hull is seen by the camera but does not
    block light, the way it behaves in Roblox."""
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission", "visible_volume_scatter"):
        if hasattr(outline, attr):
            setattr(outline, attr, False)


def frame(n, spin=0.0):
    """A rotation matrix whose Z is the unit normal n (X / Y tangent), turned `spin` about n."""
    n = Vector(n).normalized()
    rot = n.to_track_quat("Z", "Y").to_matrix().to_4x4()
    return rot @ Matrix.Rotation(spin, 4, "Z")


def flat_poly(pal, poly, p, n, spin=0.0, lift=0.004, name="spot", outline=False):
    """A flat 2D shape (star-shaped round its origin: a fan) laid tangent at surface point p, normal n."""
    m = Matrix.Translation(Vector(p) + Vector(n).normalized() * lift) @ frame(n, spin)
    bm = bmesh.new()
    c = bm.verts.new(m @ Vector((0, 0, 0)))
    ring = [bm.verts.new(m @ Vector((x, y, 0))) for x, y in poly]
    for i in range(len(ring)):
        bm.faces.new((c, ring[i], ring[(i + 1) % len(ring)]))
    bm.normal_update()
    if sum(f.normal.dot(Vector(n)) for f in bm.faces) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    return piece(bm, pal, name, outline)


def sparkle(pal, p, n, r, spin=0.0, lift=0.006, name="sparkle"):
    """A four-point glitter star (pointy, thin waist) laid on the surface at p."""
    pts = []
    for i in range(8):
        a = math.pi / 2 + i * math.pi / 4
        rr = r if i % 2 == 0 else r * 0.26
        pts.append((rr * math.cos(a), rr * math.sin(a)))
    return flat_poly(pal, pts, p, n, spin, lift, name)


def gem(cols, p, n, r, h=None, facets=6, spin=0.0, sink=0.25, name="gem"):
    """A small faceted jewel set on a surface at p (normal n): a flat table on top, a ring of crown
    facets, a girdle, flat-shaded. cols = (light, mid, dark) palette indices. r = girdle radius."""
    h = r * 0.75 if h is None else h
    m = Matrix.Translation(Vector(p)) @ frame(n, spin)
    bm = bmesh.new()
    zb = -h * sink
    bot = [bm.verts.new(m @ Vector((r * 0.92 * math.cos(a), r * 0.92 * math.sin(a), zb)))
           for a in (2 * math.pi * k / facets for k in range(facets))]
    gir = [bm.verts.new(m @ Vector((r * math.cos(a), r * math.sin(a), h * 0.32)))
           for a in (2 * math.pi * k / facets for k in range(facets))]
    tab = [bm.verts.new(m @ Vector((r * 0.55 * math.cos(a), r * 0.55 * math.sin(a), h)))
           for a in (2 * math.pi * (k + 0.5) / facets for k in range(facets))]
    pal = []
    key = Vector((-0.4, -0.5, 0.77)).normalized()
    for k in range(facets):
        j = (k + 1) % facets
        bm.faces.new((bot[k], bot[j], gir[j], gir[k]))
        pal.append(cols[2])
        f = bm.faces.new((gir[k], gir[j], tab[k]))
        f2 = bm.faces.new((tab[k], tab[k - 1], gir[k]))
        for ff in (f, f2):
            ff.normal_update()
            pal.append(cols[0] if ff.normal.dot(key) > 0.55 else (cols[1] if ff.normal.dot(key) > -0.1 else cols[2]))
    bm.faces.new(list(reversed(bot)))
    pal.append(cols[2])
    bm.faces.new(tab)
    pal.append(cols[0])
    bm.normal_update()
    if sum((f.calc_center_median() - m.translation).dot(f.normal) for f in bm.faces) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    return piece(bm, pal, name, outline=False, smooth_=False)


def ribbon(surf, t0, t1, a, w, pal, n=12, lift=0.004, name="ribbon", taper=True):
    """A thin flat stripe along a surface: surf(t, a) -> (point, normal) for t along, a across;
    from t0 to t1 at across position a, half width w (tapered to points at both ends)."""
    bm = bmesh.new()
    left, right = [], []
    for i in range(n + 1):
        t = t0 + (t1 - t0) * i / n
        k = math.sin(math.pi * i / n) ** 0.5 if taper else 1.0
        pl, nl = surf(t, a - w * max(k, 0.12))
        pr, nr = surf(t, a + w * max(k, 0.12))
        left.append(bm.verts.new(pl + nl * lift))
        right.append(bm.verts.new(pr + nr * lift))
    for i in range(n):
        bm.faces.new((left[i], right[i], right[i + 1], left[i + 1]))
    bm.normal_update()
    _p, nn = surf((t0 + t1) / 2, a)
    if sum(f.normal.dot(nn) for f in bm.faces) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    return piece(bm, pal, name, outline=False)


def lathe(profile, seg, mat, colour, name, outline=True):
    """A closed surface of revolution round local +X: profile = [(x, r, tag)], from r = 0 round to
    r = 0. colour(tag, normal) -> palette index (normal in world space)."""
    bm = bmesh.new()
    rings, tags = [], []
    for x, r, _t in profile:
        if r <= 1e-9:
            rings.append([bm.verts.new((x, 0, 0))])
        else:
            rings.append([bm.verts.new((x, r * math.cos(a), r * math.sin(a))) for a in (j / seg * math.tau for j in range(seg))])
    for i in range(len(rings) - 1):
        a, b, t = rings[i], rings[i + 1], profile[i][2]
        if len(a) == 1 or len(b) == 1:
            ring = b if len(a) == 1 else a
            ctr = a[0] if len(a) == 1 else b[0]
            for j in range(seg):
                k = (j + 1) % seg
                bm.faces.new((ctr, ring[j], ring[k]))
                tags.append(t)
            continue
        for j in range(seg):
            k = (j + 1) % seg
            bm.faces.new((a[j], a[k], b[k], b[j]))
            tags.append(t)
    outward(bm)
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    bm.normal_update()
    pal = [colour(t, f.normal) for f, t in zip(bm.faces, tags)]
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline, True, name)


def superbox(cols, size, mat, cuts=(-0.4, 0.62), e=3.2, seg=24, rows=10, name="box", outline=True, field=None,
             bulge=0.0, metal=False):
    """A soft rounded box: a superellipsoid (exponent e: 2 = ellipsoid, higher = boxier) of half sizes
    `size`, toned by normal z (or field(vert, world point)), placed by `mat`. Chunky toy plastic with
    no hard edges for the hull to crease on. `bulge` puffs the faces out a little."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rows, radius=1.0)
    sx, sy, sz = size

    def sp(x):
        return math.copysign(abs(x) ** (2.0 / e), x)
    for v in bm.verts:
        q = v.co.normalized()
        b = 1.0 + bulge * (1.0 - max(abs(q.x), abs(q.y), abs(q.z)) ** 2)
        v.co = Vector((sp(q.x) * sx * b, sp(q.y) * sy * b, sp(q.z) * sz * b))
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    return toned(bm, cols, cuts, name, outline, field, metal)


def catmull(points, n):
    """Open Catmull-Rom curve through `points` (Vectors) -> n + 1 points (ends kept)."""
    pts = [Vector(p) for p in points]
    k = len(pts) - 1
    out = []
    for i in range(n + 1):
        u = i / n * k
        j = min(int(u), k - 1)
        t = u - j
        p0, p1, p2, p3 = (pts[min(max(m, 0), k)] for m in (j - 1, j, j + 1, j + 2))
        out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                          + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    return out


def sweep_bm(path, w, h, side=(1, 0, 0), e=3.0, seg=12, res=16, scale=None):
    """A closed soft-cornered bar along `path` (a Catmull-Rom through the points): a superellipse
    cross-section (exponent e) w across `side` and h across the path's other normal, `scale(t)` per
    point (t 0..1). Flat-ish caps. -> bmesh."""
    pts = catmull(path, res)
    side = Vector(side).normalized()
    bm = bmesh.new()
    rings = []
    for i, c in enumerate(pts):
        tan = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        sd = (side - tan * tan.dot(side)).normalized()
        up = tan.cross(sd)
        k = scale(i / (len(pts) - 1)) if scale else 1.0
        ring = []
        for j in range(seg):
            a = j / seg * math.tau
            ca, sa = math.cos(a), math.sin(a)
            x = math.copysign(abs(ca) ** (2.0 / e), ca) * w * k
            y = math.copysign(abs(sa) ** (2.0 / e), sa) * h * k
            ring.append(bm.verts.new(c + sd * x + up * y))
        rings.append(ring)
    for i in range(len(rings) - 1):
        for j in range(seg):
            m = (j + 1) % seg
            bm.faces.new((rings[i][j], rings[i][m], rings[i + 1][m], rings[i + 1][j]))
    c0, c1 = bm.verts.new(pts[0]), bm.verts.new(pts[-1])
    for j in range(seg):
        m = (j + 1) % seg
        bm.faces.new((c0, rings[0][m], rings[0][j]))
        bm.faces.new((c1, rings[-1][j], rings[-1][m]))
    outward(bm)
    return bm


# ---------------------------------------------------------------- golden palette
GOLD_KEY = Vector((-0.42, -0.5, 0.76)).normalized()   # the painted key light the gold shines toward
GOLD_CUTS = (-0.8, -0.35, 0.8)                        # metal_value: deep / dark / base / light


def metal_value(n):
    """The value polished metal is toned by: how much the normal faces the key light."""
    return Vector(n).normalized().dot(GOLD_KEY)


def metal_tone(cols, v):
    """Polished metal (cols = light, base, dark, deep) by metal_value: a crisp hot highlight where the
    surface faces the key light, rich gold, a darker amber turning away, deep in the shadow. Cut the
    mesh along GOLD_CUTS of metal_value first."""
    for c, i in zip(reversed(GOLD_CUTS), range(3)):
        if v > c:
            return cols[i]
    return cols[3]


def metal_piece(bm, cols, name, outline=True, extra_cuts=()):
    """Cuts a closed bmesh along GOLD_CUTS and colours it with metal_tone -> Piece."""
    outward(bm)
    bm.normal_update()
    vals = {v: metal_value(v.normal) for v in bm.verts}
    iso_cut(bm, vals, sorted(set(GOLD_CUTS) | set(extra_cuts)))
    pal = [metal_tone(cols, sum(vals[v] for v in f.verts) / len(f.verts)) for f in bm.faces]
    return piece(bm, pal, name, outline)


def gold_colours(prefix):
    """-> dict of the golden version's shared colours, registered as `<prefix>_gold...` (the bake paints
    them as metal: list `<prefix>_gold` in MATERIALS), gems (`<prefix>_gem_...`: glass) and glitter."""
    G = {}
    G["gold"] = (hexcol(f"{prefix}_gold_light", "#FFF0B4"), hexcol(f"{prefix}_gold", "#FDB830"),
                 hexcol(f"{prefix}_gold_dark", "#D9881C"), hexcol(f"{prefix}_gold_deep", "#9C5418"))
    G["shine"] = hexcol(f"{prefix}_gold_shine", "#FFF6D2")
    G["ruby"] = (hexcol(f"{prefix}_gem_ruby_light", "#FFB3C6"), hexcol(f"{prefix}_gem_ruby", "#FF2E63"),
                 hexcol(f"{prefix}_gem_ruby_dark", "#B0103E"))
    G["sapphire"] = (hexcol(f"{prefix}_gem_sapphire_light", "#B8E6FF"), hexcol(f"{prefix}_gem_sapphire", "#2E9BFF"),
                     hexcol(f"{prefix}_gem_sapphire_dark", "#1650B8"))
    G["emerald"] = (hexcol(f"{prefix}_gem_emerald_light", "#B8FFD8"), hexcol(f"{prefix}_gem_emerald", "#21D47A"),
                    hexcol(f"{prefix}_gem_emerald_dark", "#0E8A4C"))
    G["amethyst"] = (hexcol(f"{prefix}_gem_amethyst_light", "#EBC8FF"), hexcol(f"{prefix}_gem_amethyst", "#B05CFF"),
                     hexcol(f"{prefix}_gem_amethyst_dark", "#6E2CB8"))
    G["diamond"] = (hexcol(f"{prefix}_gem_diamond_light", "#FFFFFF"), hexcol(f"{prefix}_gem_diamond", "#DDF6FF"),
                    hexcol(f"{prefix}_gem_diamond_dark", "#9CCDE8"))
    G["sparkle"] = hexcol(f"{prefix}_sparkle", "#FFFFFF")
    G["glitter"] = hexcol(f"{prefix}_sparkle_gold", "#FFF7C2")
    return G


GEM_ORDER = ("ruby", "sapphire", "emerald", "amethyst", "diamond")


def shine_bars(bvh, origin, du, dv, along, size, pal, lift=0.006, name="shine", step=0.05, tilt=0.55):
    """Two parallel diagonal shine bars (a wide one and a thin one) painted across a flat golden
    face: the toon way to say "polished metal" on a flat side. size = (half width, half height) of the
    face in du / dv units."""
    hw, hh = size
    out = []
    for off, w in ((-0.16, 0.2), (0.2, 0.08)):
        c = Vector((off * hw * 2.0, 0.0))
        d = Vector((math.sin(tilt), math.cos(tilt)))      # along the bar (leaning right)
        nrm = Vector((d.y, -d.x))
        L = hh * 0.82
        ww = w * min(hw, hh)
        poly = [c - d * L - nrm * ww, c - d * L + nrm * ww, c + d * L + nrm * ww, c + d * L - nrm * ww]
        poly = [tuple(p) for p in poly]
        if _area(poly) < 0:
            poly.reverse()
        out.append(decal(bvh, poly, origin, du, dv, along, lift, pal, name, step=step))
    return out


def _area(poly):
    return 0.5 * sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
                     for i in range(len(poly)))


# ---------------------------------------------------------------- skeletons
class Bone:
    """A bone: head -> tail (Blender local +Y), its local +Z toward `z` (default: the item's front
    -Y, or up for a bone that points along the front), `parent` a bone name or None."""

    def __init__(self, name, parent, head, tail, z=None, deform=True):
        self.name, self.parent, self.deform = name, parent, deform
        self.head, self.tail = Vector(head), Vector(tail)
        axis = (self.tail - self.head).normalized()
        if z is None:
            z = Vector((0, -1, 0)) if abs(axis.y) < 0.8 else Vector((0, 0, 1))
        z = Vector(z)
        self.z = (z - axis * z.dot(axis)).normalized()


def armature(name, bones, matrix_world=None):
    """The armature object `name` from a list of Bone (parents before children)."""
    arm = bpy.data.armatures.new(name)
    ao = bpy.data.objects.new(name, arm)
    K.link(ao)
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    vl.objects.active = ao
    bpy.ops.object.mode_set(mode="EDIT")
    for b in bones:
        eb = arm.edit_bones.new(b.name)
        eb.head, eb.tail = b.head, b.tail
        eb.use_deform = b.deform
        if b.parent:
            eb.parent = arm.edit_bones[b.parent]
            eb.use_connect = False
        eb.align_roll(b.z)
    bpy.ops.object.mode_set(mode="OBJECT")
    arm.display_type = "STICK"
    if matrix_world is not None:
        ao.matrix_world = matrix_world.copy()
    return ao


def skin(name, objs, bones, fields, rigid=None):
    """Builds `<name>_Rig` from `bones` and skins the body (objs[0]) and its `_Outline` per the pieces'
    rig tags (see the module doc). `rigid` = {object name: bone}: other meshes (glow parts) weighted
    100% to that bone. Returns the armature object."""
    body = objs[0]
    info = K.PIECE_MAP[name]
    names = {b.name for b in bones}

    def resolve(t, p):
        if t in fields:
            return fields[t](p)
        if t in names:
            return {t: 1.0}
        raise KeyError(f"{name}: piece tag {t!r} is neither a bone nor a field")
    co = [v.co.copy() for v in body.data.vertices]          # model space (preview may move the object)
    W = [None] * len(co)
    for i, r in enumerate(info["body"]):
        if r is None:
            continue
        s, n = r
        t = info["tags"][i]
        for k in range(s, s + n):
            W[k] = rigging._finalise(resolve(t, co[k]))
    assert all(w is not None for w in W), f"{name}: body vertices without weights"
    ao = armature(name + "_Rig", bones, body.matrix_world)
    rigging._skin(body, ao, W)
    outline = next((o for o in objs if o.name == name + "_Outline"), None)
    if outline is not None:
        oco = [v.co.copy() for v in outline.data.vertices]
        WO = [None] * len(oco)
        for pi, s, n in info["outline"]:
            br = info["body"][pi]
            for k in range(n):
                WO[s + k] = W[br[0] + k] if br is not None else rigging._finalise(resolve(info["tags"][pi], oco[s + k]))
        assert all(w is not None for w in WO), f"{name}: outline vertices without weights"
        rigging._skin(outline, ao, WO)
    for o in objs:
        if rigid and o.name in rigid:
            rigging._skin(o, ao, [{rigid[o.name]: 1.0}] * len(o.data.vertices))
    return ao
