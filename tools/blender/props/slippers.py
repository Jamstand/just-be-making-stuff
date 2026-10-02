"""
props/slippers.py - the Slippers prop (ReplicatedStorage.MapMeshes.Slippers): a pair of fuzzy
lavender bunny slippers kicked off side by side on the bedroom floor, the right one turned a bit.
See props/__init__.py for the conventions every prop follows.

Each slipper (toe toward -Y before it is turned) is a plush body - one superquadric loft whose
roof swells into a round bunny head over the toes and dips into the foot opening at the back -
sitting on a plum sole a touch bigger than its footprint (the sole's ink line reads as the seam).
The opening is a dark pink lining ringed by a fluffy white scalloped collar; a white pom-pom tail
sits on the heel. On the head: two black button eyes (raised rim, sewn with lavender thread), a
little pink nose, a tiny ink mouth, pink cheeks, and two long floppy ears that rise from the crown
and droop down beside the slipper, pink inside. Left and right slippers are mirror images built
from the same functions (no negative scales). Plush tones are cut along smooth iso-lines of the
surface normal, so the lit / base / shaded areas have clean curved borders.
"""
import math
import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Slippers"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"slippers_ear_in": "felt", "slippers_cheek": "felt"}

PLUSH = (hexcol("slippers_plush_light", "#DCCBFF"), hexcol("slippers_plush", "#BCA4F2"),
         hexcol("slippers_plush_dark", "#957AD8"), hexcol("slippers_plush_deep", "#7458B9"))
SOLE = (hexcol("slippers_sole_light", "#8169BE"), hexcol("slippers_sole", "#6A53A8"), hexcol("slippers_sole_dark", "#4E3D84"))
LINING = hexcol("slippers_lining", "#D86E9E")
LINING_D = hexcol("slippers_lining_dark", "#B4507F")
FLUFF = (hexcol("slippers_fluff_light", "#FFFFFF"), hexcol("slippers_fluff", "#FBF3FA"), hexcol("slippers_fluff_dark", "#DCCCE6"))
EAR_IN = (hexcol("slippers_ear_in_light", "#FFC0D9"), hexcol("slippers_ear_in", "#FFA2C6"))
NOSE = (hexcol("slippers_nose_light", "#FFA9CB"), hexcol("slippers_nose", "#FF79AA"))
CHEEK = hexcol("slippers_cheek", "#F6A3D2")
BUTTON = (hexcol("slippers_button_rim", "#4B3E5F"), hexcol("slippers_button", "#211830"))
THREAD = hexcol("slippers_thread", "#E6DAFF")
INK = hexcol("slippers_ink", "#3E2440")

TONE_CUTS = (-0.5, -0.1, 0.8)    # normal z: deep / shade / base / lit (only the crown: no tone edge across the face)
HALF_L = 2.25                    # half length of the plush body
OPEN_C = Vector((0.0, 0.92))     # foot opening centre (x, y) ...
OPEN_A = (0.6, 0.95)             # ... and half axes
FLOOR = 0.08                     # the body's underside (inside the sole)

# body stations (y, half width, roof z) - toe at -Y
STATIONS = [(-2.25, 0.84, 0.95), (-1.65, 0.98, 1.24), (-0.95, 1.04, 1.38), (-0.35, 1.0, 1.28), (0.25, 0.96, 1.0),
            (1.1, 0.92, 0.92), (1.75, 0.9, 0.94), (2.25, 0.84, 0.9)]


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


def _smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def _spow(x, e):
    return math.copysign(abs(x) ** e, x)


def _interp(y, rows, col):
    """Catmull-Rom through rows[i][0] -> rows[i][col]."""
    if y <= rows[0][0]:
        return rows[0][col]
    if y >= rows[-1][0]:
        return rows[-1][col]
    i = max(k for k in range(len(rows) - 1) if rows[k][0] <= y)
    a, b, c, d = (rows[min(max(k, 0), len(rows) - 1)][col] for k in (i - 1, i, i + 1, i + 2))
    t = (y - rows[i][0]) / (rows[i + 1][0] - rows[i][0])
    return 0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t ** 3)


def _tone(cols, nz):
    if nz > TONE_CUTS[2]:
        return cols[0]
    if nz > TONE_CUTS[1]:
        return cols[1]
    if nz > TONE_CUTS[0] or len(cols) < 4:
        return cols[2]
    return cols[3]


def _loft(q, inner, grow=0.0, roof=None, floor=FLOOR, equator=0.36, dip=True):
    """Unit sphere point (pole on Y) -> slipper surface (slipper-local, toe -Y). `inner` = +1 or -1:
    the side of the big toe (+X for the left slipper) - the toe end leans that way a little."""
    u, v, w = q
    e1 = 0.6
    y = _spow(v, e1) * (HALF_L + grow)
    r = math.sqrt(max(0.0, u * u + w * w))
    rr = r ** e1
    cu, cw = (u / r, w / r) if r > 1e-9 else (0.0, 0.0)
    hw = _interp(y, STATIONS, 1) + grow
    x = hw * rr * _spow(cu, 0.62)
    x += inner * 0.13 * _smooth(-0.6, -2.2, y)          # big-toe side: the toe leans inward
    top = roof if roof is not None else _interp(y, STATIONS, 2)
    if w >= 0:
        z = equator + (top - equator) * rr * _spow(cw, 0.75)
    else:
        z = equator + (equator - floor) * rr * _spow(cw, 0.3)
    if dip and w > 0:   # the foot opening: a soft hollow in the roof at the back
        d = ((x - OPEN_C.x) / (OPEN_A[0] + 0.12)) ** 2 + ((y - OPEN_C.y) / (OPEN_A[1] + 0.12)) ** 2
        z -= 0.42 * _smooth(1.0, 0.35, d) * _smooth(0.1, 0.7, cw)
    return Vector((x, y, z))


def _outward(bm):
    """Turns a closed mesh's faces outward (by its signed volume; recalc_face_normals guesses wrong
    on these flat-bottomed shapes)."""
    vol = 0.0
    for f in bm.faces:
        vs = [v.co for v in f.verts]
        for i in range(1, len(vs) - 1):
            vol += vs[0].dot(vs[i].cross(vs[i + 1]))
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])


def _sphere_piece(fn, seg, rings, pal, name, cuts=TONE_CUTS, outline=True):
    """UV sphere (poles moved to +-Y by a cyclic axis swap, which keeps the winding) mapped through
    fn(Vector) -> world; coloured pal(nz) per face after cutting along `cuts` of the normal z."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
    for vt in bm.verts:
        x, y, z = vt.co
        vt.co = fn(Vector((y, z, x)))
    _outward(bm)
    bm.normal_update()
    if not callable(pal):
        return K.Piece(K._bm_to_mesh(bm, name), pal, outline, True, name)
    vals = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, vals, cuts)
    fp = [pal(sum(vals[v] for v in f.verts) / len(f.verts)) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, name), fp, outline, True, name)


def _body(inner):
    """The plush body; the foot opening's lining is cut into its roof along the opening's oval."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=24, v_segments=15, radius=1.0)
    for vt in bm.verts:
        x, y, z = vt.co
        vt.co = _loft(Vector((y, z, x)), inner)
    _outward(bm)
    bm.normal_update()
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
        if oval(c) < 1.0 and c.z > 0.3:
            fp.append(LINING if n > 0.75 else LINING_D)
        else:
            fp.append(_tone(PLUSH, n))
    return K.Piece(K._bm_to_mesh(bm, "body"), fp, True, True, "body")


def _bvh(piece):
    me = piece.mesh
    return BVHTree.FromPolygons([v.co.copy() for v in me.vertices], [tuple(p.vertices) for p in me.polygons])


def _hit(bvh, o, d):
    loc, nor, _i, _d = bvh.ray_cast(Vector(o), Vector(d).normalized())
    return loc, nor


LOOK = Vector((0, 1, -0.3)).normalized()   # the face features are placed looking at the head from the front, a little above


def _face_hit(bvh, x, z):
    """Point on the front of the head roughly at height z (a ray aimed at (x, -1.7, z))."""
    target = Vector((x, -1.7, z))
    return _hit(bvh, target - LOOK * 6.0, LOOK)


def _loop_tube(points, radii, sides, pal, name, up=Vector((0, 0, 1)), outline=True):
    """A closed ring tube through `points`, radius radii[i] at each point; pal(normal) -> index."""
    bm = bmesh.new()
    n = len(points)
    rings = []
    for i in range(n):
        t = (Vector(points[(i + 1) % n]) - Vector(points[i - 1])).normalized()
        nn = (up - t * up.dot(t)).normalized()
        b = t.cross(nn)
        c = Vector(points[i])
        rings.append([bm.verts.new(c + (nn * math.cos(a) + b * math.sin(a)) * radii[i])
                      for a in (j / sides * math.tau for j in range(sides))])
    for i in range(n):
        a, b = rings[i], rings[(i + 1) % n]
        for j in range(sides):
            k = (j + 1) % sides
            bm.faces.new((a[j], b[j], b[k], a[k]))
    _outward(bm)
    bm.normal_update()
    fp = [pal(f.normal) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, name), fp, outline, True, name)


def _bezier(pts, t):
    p0, p1, p2, p3 = (Vector(p) for p in pts)
    s = 1 - t
    return p0 * s ** 3 + p1 * 3 * s * s * t + p2 * 3 * s * t * t + p3 * t ** 3


def _ear(ctrl, width, thick, ref, name="ear"):
    """A long floppy ear: a flattened ellipsoid bent along the cubic bezier `ctrl` (base -> tip),
    widest a little past the middle; its flat face turns toward `ref`. Returns (ear piece, pink
    inner-ear sheet on the `ref` face)."""
    def frame(t):
        p = _bezier(ctrl, t)
        tan = (_bezier(ctrl, min(1.0, t + 0.01)) - _bezier(ctrl, max(0.0, t - 0.01))).normalized()
        b = (ref - tan * ref.dot(tan)).normalized()
        n = b.cross(tan)
        return p, n, b

    def wid(t):
        return width * (0.62 + 0.45 * math.sin(math.pi * min(1.0, t * 1.1)))

    def surf(u, v, w, lift=0.0):
        t = (v + 1) / 2
        p, n, b = frame(t)
        blunt = max(1e-3, 1 - v * v) ** -0.22 if abs(v) < 0.999 else 1.0   # rounder, spoon-shaped ends
        return p + n * (u * wid(t) * min(blunt, 1.8)) + b * (w * thick + lift)

    def fn(q):
        u, v, w = q
        return surf(u, v, w)
    ear = _sphere_piece(fn, 10, 8, lambda nz: _tone(PLUSH, nz), name)
    # inner ear: an oval on the ref face, lifted a hair
    bm = bmesh.new()
    seg, rings = 16, 2
    pts = {}

    def vert(r, a):
        u, v = 0.62 * r * math.cos(a), -0.05 + 0.72 * r * math.sin(a)
        w = math.sqrt(max(0.0, 1 - u * u - v * v))
        return bm.verts.new(surf(u, v, w, 0.02 * (1 - 0.5 * r * r)))
    mid = vert(0, 0)
    for i in range(1, rings + 1):
        for j in range(seg):
            pts[i, j] = vert(i / rings, j / seg * math.tau)
    for j in range(seg):
        bm.faces.new((mid, pts[1, j], pts[1, (j + 1) % seg]))
    for i in range(1, rings):
        for j in range(seg):
            bm.faces.new((pts[i, j], pts[i + 1, j], pts[i + 1, (j + 1) % seg], pts[i, (j + 1) % seg]))
    bm.normal_update()
    _p0, _n0, b0 = frame(0.5)
    if sum(f.normal.dot(b0) for f in bm.faces) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    bm.normal_update()
    fp = [EAR_IN[0] if f.normal.z > 0.62 else EAR_IN[1] for f in bm.faces]
    return ear, K.Piece(K._bm_to_mesh(bm, "ear_in"), fp, False, True, "ear_in")


def _pompom(c, r):
    """A fluffy ball: a sphere with soft lumps (a few smooth lobes), so its outline is scalloped."""
    lobes = [Vector(d).normalized() for d in ((1, 0.2, 0.3), (-0.8, 0.4, 0.5), (0.1, 1, 0.2), (0.3, -0.2, 1), (-0.4, -0.9, 0.1),
                                              (0.5, 0.6, -0.6), (-0.6, 0.1, -0.7), (0.9, -0.6, -0.2), (-0.3, 0.8, 0.9))]

    def fn(q):
        d = Vector(q).normalized() if Vector(q).length > 1e-9 else Vector((0, 0, 1))
        bump = sum(math.exp(-(1 - d.dot(l)) / 0.08) for l in lobes)
        return c + d * r * (0.86 + 0.2 * min(1.0, bump))
    return _sphere_piece(fn, 9, 6, lambda nz: _tone(FLUFF, nz), "pompom", cuts=(-0.1, 0.8))


def _button(pos, nor, up):
    """A sewn-on button eye: a lathe disc with a raised rim and a dished centre, two thread dots."""
    nor = nor.normalized()
    side = up.cross(nor).normalized()
    upv = nor.cross(side)
    rot = Matrix((side, upv, nor)).transposed().to_4x4()
    m = Matrix.Translation(pos) @ rot
    prof = [(0.0, -0.06), (0.19, -0.06), (0.2, 0.0), (0.17, 0.05), (0.12, 0.035), (0.0, 0.03)]
    bm = bmesh.new()
    seg = 12
    rings = []
    for r, z in prof:
        if r < 1e-9:
            rings.append([bm.verts.new((0, 0, z))])
        else:
            rings.append([bm.verts.new((r * math.cos(a), r * math.sin(a), z)) for a in (j / seg * math.tau for j in range(seg))])
    tags = []
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        tag = "face" if i >= 3 else "rim"
        for j in range(seg):
            k = (j + 1) % seg
            if len(a) == 1:
                bm.faces.new((a[0], b[k], b[j]))
            elif len(b) == 1:
                bm.faces.new((a[j], a[k], b[0]))
            else:
                bm.faces.new((a[j], a[k], b[k], b[j]))
            tags.append(tag)
    _outward(bm)
    bmesh.ops.transform(bm, matrix=m, verts=bm.verts)
    fp = [BUTTON[0] if t == "rim" else BUTTON[1] for t in tags]
    out = [K.Piece(K._bm_to_mesh(bm, "button"), fp, False, True, "button")]
    for s in (-1, 1):
        q = pos + nor * 0.04 + side * (s * 0.05)
        out.append(K.cylinder(THREAD, 0.03, 0.02, Matrix.Translation(q) @ rot, seg=5, outline=False, name="thread"))
    return out


def _slipper(inner, ears):
    """One slipper in its own frame (toe -Y, floor at z = 0). `inner` = side of the big toe."""
    p = []
    body = _body(inner)
    p.append(body)
    p.append(_sphere_piece(lambda q: _loft(q, inner, grow=0.07, roof=0.24, floor=0.0, equator=0.1, dip=False), 18, 5,
                           lambda nz: _tone(SOLE, nz), "sole", cuts=(0.8,)))
    bvh = _bvh(body)
    # foot opening (its pink lining is cut into the body): a fluffy scalloped collar round it
    n_b, per = 9, 3
    pts, radii = [], []
    for i in range(n_b * per):
        t = i / (n_b * per) * math.tau
        x, y = OPEN_C.x + (OPEN_A[0] + 0.05) * math.cos(t), OPEN_C.y + (OPEN_A[1] + 0.05) * math.sin(t)
        loc, _n = _hit(bvh, (x, y, 5.0), (0, 0, -1))
        pts.append(tuple(loc + Vector((0, 0, 0.06))))
        radii.append(0.15 * (1 + 0.22 * math.cos(i / per * math.tau)))
    p.append(_loop_tube(pts, radii, 4, lambda n: _tone(FLUFF, n.z), "collar"))
    p.append(_pompom(Vector((0.0, HALF_L + 0.12, 0.62)), 0.36))
    # face on the front of the head
    for s in (-1, 1):
        loc, nor = _face_hit(bvh, s * 0.4, 1.0)
        p += _button(loc + nor * 0.03, nor, Vector((0, 0, 1)))
        cl, cn = _face_hit(bvh, s * 0.66, 0.74)
        cm = Matrix.Translation(cl + cn * 0.012) @ cn.to_track_quat("Z", "Y").to_matrix().to_4x4()
        p.append(K.cylinder(CHEEK, 0.16, 0.012, cm @ Matrix.Diagonal((1.0, 0.7, 1.0, 1.0)), seg=10, outline=False,
                            name="cheek"))
    nl, nn = _face_hit(bvh, 0.0, 0.8)
    nm = Matrix.Translation(nl + nn * 0.06) @ nn.to_track_quat("Z", "Y").to_matrix().to_4x4()

    def nose(q):
        u, v, w = q
        x, y, z = u * 0.19, v * 0.12, w * 0.09
        y *= 1 - 0.5 * max(0.0, -v)   # a rounded triangle, point down
        x *= 1 - 0.55 * max(0.0, -v)
        return nm @ Vector((x, y, z))
    p.append(_sphere_piece(nose, 8, 6, lambda nz: NOSE[0] if nz > 0.62 else NOSE[1], "nose", cuts=(0.62,), outline=False))
    mouth = []
    for i in range(5):
        x = -0.14 + 0.28 * i / 4
        zz = 0.63 - 0.035 * math.cos((x / 0.14) * math.pi * 1.0)   # a little "w"
        loc, nor = _face_hit(bvh, x, zz)
        mouth.append(tuple(loc + nor * 0.012))
    p.append(K.tube(INK, mouth, radius=0.024, res=2, bevel_res=0, outline=False, name="mouth"))
    for ctrl, ref in ears:
        e, ei = _ear(ctrl, 0.34, 0.1, ref)
        p += [e, ei]
    return p


def _ears(inner, flop_back=False):
    """Control points of both ears for a slipper whose big toe is on the `inner` side."""
    out = []
    for s in (-1, 1):
        base = Vector((s * 0.36, -0.9, 1.22))
        if flop_back and s == inner:
            # this one flops back over the opening and hangs off the heel side
            ctrl = [base, base + Vector((s * 0.12, 0.25, 0.5)), Vector((s * 0.5, 0.75, 1.35)), Vector((s * 1.02, 1.55, 0.62))]
            ref = Vector((s * 0.5, 0.2, 1.0))
        else:
            ctrl = [base, base + Vector((s * 0.26, 0.02, 0.75)), Vector((s * 1.25, -0.3, 1.38)), Vector((s * 1.5, 0.45, 0.2))]
            ref = Vector((s * 0.75, 0.0, 0.75))
        out.append((ctrl, ref.normalized()))
    return out


def _place(pieces, m):
    for pc in pieces:
        pc.mesh.transform(m)
    return pieces


LAYOUT = [(1, (-1.42, -0.12), 0.08, False), (-1, (1.45, -0.49), -0.42, True)]   # (inner, (x, y), yaw, ear flops back)


def build():
    p = []
    for inner, (x, y), yaw, flop in LAYOUT:
        p += _place(_slipper(inner, _ears(inner, flop)), M((x, y, 0), rot=(0, 0, yaw)))
    body, outline = K.finish(p, NAME, outline_width=0.07)
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission", "visible_volume_scatter"):
        if hasattr(outline, attr):  # preview only: the hull must not block light (it doesn't in Roblox)
            setattr(outline, attr, False)
    return [body, outline] + K.markers(NAME)
