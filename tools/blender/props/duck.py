"""
props/duck.py - the Duck prop (ReplicatedStorage.MapMeshes.Duck). See props/__init__.py for
the conventions every prop follows.

Classic yellow rubber duck from the bedroom keyframe: a plump body whose back dips into a saddle
behind the head and rises again to a narrow, pointed tail tip flicking up at the very back (about
bill height), a big round head set forward, a short, broad wedge of an orange bill (thick at the
face, its top meeting the face just under the eye, tapering to a thinner, slightly lifted tip over
a shorter lower bill, an ink line between them), round glossy dark eyes with a white glint, raised
wing panels on the rear flanks (front edge bowed forward, top edge dipping in the middle, short ink
accents only where the art has them), and a deeper yellow following the curve of the undersides.
Colour bands are cut along smooth iso-lines of the surface normal, so every tone boundary is a
clean curve rather than a saw-tooth of faces. Colours were sampled from
docs/concept/bedroom_keyframe.png.
"""
import math
import bmesh
import sockkit as K
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Duck"

D_BASE = hexcol("duck_body", "#F6C619")     # lit body yellow (art: #F5C411)
D_TOP = hexcol("duck_top", "#FBD740")       # top-facing highlight
D_SHADE = hexcol("duck_shade", "#E4A212")   # undersides / wing face (art: #E6A309)
D_DEEP = hexcol("duck_deep", "#C98010")     # the very bottom (art: #D0810D)
B_BASE = hexcol("duck_bill", "#FC7B03")     # upper bill (art: #FB8006 lit)
B_TOP = hexcol("duck_bill_top", "#FD8C1C")  # lit crown of the upper bill
B_LOW = hexcol("duck_bill_low", "#F06A08")  # lower bill, lit lip
B_LOW_SH = hexcol("duck_bill_low_sh", "#C24A0A")  # underside of the lower bill (art: #B53B08)
EYE = hexcol("duck_eye", "#2A140E")
INK = hexcol("duck_ink", "#2A1A14")         # drawn ink accents: the hull's rendered dark brown


def _smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


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


def _gather(q, d, k, w):
    """Moves unit vector q toward unit vector d: angle a -> a * (1 - k * exp(-(a / w)^2))."""
    a = math.acos(max(-1.0, min(1.0, q.dot(d))))
    perp = q - d * q.dot(d)
    if perp.length < 1e-9:
        return q
    a2 = a * (1 - k * math.exp(-(a / w) ** 2))
    return d * math.cos(a2) + perp.normalized() * math.sin(a2)


def _blob(fn, pal, seg=24, rings=14, name="blob", outline=True, cuts=None, field=None, pole=None, dense=None):
    """A UV sphere whose unit-sphere vertices are mapped through fn(Vector) -> world position.
    `pal` is a palette index, or pal(value) -> index, coloured per face from `field(co, normal)`
    (default: the smooth vertex normal's z) after cutting the mesh along `cuts`, so the bands have
    clean edges. `pole` = "x" puts the sphere's poles on +-X (for the wing panels). `dense` =
    (direction, strength, width) gathers the vertices toward that direction (more detail there,
    e.g. round the tail tip) without changing the shape."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
    for v in bm.verts:
        q = v.co.copy()
        if pole == "x":
            q = Vector((q.z, q.x, q.y))
        if dense is not None:
            q = _gather(q, *dense)
        v.co = Vector(fn(q))
    if callable(pal):
        bm.normal_update()
        field = field or (lambda co, n: n.z)
        vals = {v: field(v.co, v.normal) for v in bm.verts}
        _iso_cut(bm, vals, cuts or ())
        fp = [pal(sum(vals[v] for v in f.verts) / len(f.verts)) for f in bm.faces]
        me = K._bm_to_mesh(bm, name)
        return K.Piece(me, fp, outline, True, name)
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline, True, name)


def _camera_only_outline(outline):
    """Preview only (Cycles ray visibility, not exported): the hull is seen by the camera but does
    not block bounce light, the way it behaves in Roblox. Without this the hull paints grainy dark
    patches on the duck's back and under the bill in preview renders."""
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission",
                 "visible_volume_scatter"):
        if hasattr(outline, attr):
            setattr(outline, attr, False)


# ---------------------------------------------------------------- shapes
HEAD_C = Vector((0, -0.68, 3.58))
HEAD_R = 1.27
HEAD_S = (1.02, 0.98, 0.95)

TAIL_DIR = Vector((0, 0.75, 0.66)).normalized()
TAIL_LIFT = Vector((0, 0.56, 0.7))   # how far the tail tip stands out of the body
TAIL_EXP = 1.35                       # falloff exponent (< 2: the lobe ends in a soft point)
TAIL_UP = Vector((0, -TAIL_DIR.z, TAIL_DIR.y))   # unit, across the tail toward the head
TAIL_WX, TAIL_WF, TAIL_WR = 0.28, 0.5, 0.42    # tail extent: sideways, toward the head, down the rear


def _body_base(p):
    u, v, w = p
    w2 = w if w > -0.4 else -0.4 + (w + 0.4) * 0.42  # flat, rounded bottom
    z = 1.3 + w * 1.22 if w > 0 else (w2 + 0.652) * 1.99
    x, y = u * 1.9, 0.2 + v * 2.45
    # chest: a little fuller low at the front
    if v < 0:
        y += v * 0.12 * _smooth(-0.9, 0.2, -abs(w + 0.1))
    if w > 0:  # raise the chest up into the neck so the head sits IN the body, not on it
        # (a soft ramp in v: a hard kink here left a crease across the back whose ink hull
        # poked out beside the neck as a dark spike)
        z += 1.05 * w * 0.15 * math.log(1 + math.exp(-v / 0.15))
    # rear below the tail bulges out a little, so the back reads as one convex curve
    if v > 0:
        y += 0.3 * v * v * math.exp(-((w - 0.05) / 0.45) ** 2)
        # a full, high rear: the tail grows out of a big rounded mass, not a thin ridge
        z += 0.3 * _smooth(0.0, 0.85, v) * max(0.0, w) ** 2
        x *= 1 + 0.06 * _smooth(0.0, 0.7, v) * (1 - w * w)
    # the back dips into a saddle between the head and the tail
    if w > 0:
        # (scaled by w^2, so the back stays rounded across: no dish with raised rims)
        z -= 0.34 * math.exp(-((v - 0.5) / 0.22) ** 2) * w * w
    # under the cheeks and chin the chest swells up INTO the head, so the head's ink hull is
    # hidden there (the art has no line under the bill/cheeks, only behind the head). The swell
    # fades out well in front of the sides of the neck and blends in with a smooth max: a fade or
    # a hard max beside the neck left a crease whose hull poked out behind the head as a spike.
    if v < 0 and w > 0:
        s = (x / (HEAD_R * 1.02)) ** 2 + ((y - HEAD_C.y) / (HEAD_R * 0.98)) ** 2
        if s < 1.0:
            hb = HEAD_C.z - HEAD_R * 0.95 * math.sqrt(1.0 - s)   # head underside above this point
            f = _smooth(1.0, 0.62, s) * _smooth(-0.6, -1.15, y)
            zt = z + (hb + 0.16 - z) * f
            z = 0.5 * (z + zt + math.sqrt((z - zt) ** 2 + 0.04))   # smooth max: no crease for the hull
    return Vector((x, y, z))


def _body(p):
    """_body_base plus the tail: a narrow, soft-pointed lobe at the rear-top that flicks up and back
    (a displacement with a slightly cusped falloff: pointed at the tip, no crease down its back)."""
    P = _body_base(p)
    q = p.normalized()
    c = q.dot(TAIL_DIR)
    if c <= 0:
        return tuple(P)
    side = q.x / TAIL_WX
    along = q.dot(TAIL_UP)                   # + toward the back/head, - down the rear
    along /= TAIL_WF if along > 0 else TAIL_WR
    t = math.exp(-(side * side + along * along) ** (TAIL_EXP / 2))
    return tuple(P + TAIL_LIFT * t)


def _body_pal(nz):
    # the shading follows the curve of the belly (no flat "waterline" ring)
    if nz < -0.55:
        return D_DEEP
    if nz < -0.12:
        return D_SHADE
    if nz > 0.82:
        return D_TOP
    return D_BASE


def _head(p):
    return HEAD_C + Vector((p.x * HEAD_S[0], p.y * HEAD_S[1], p.z * HEAD_S[2])) * HEAD_R


def _head_pal(nz):
    if nz > 0.8:
        return D_TOP
    if nz < -0.6:
        return D_SHADE
    return D_BASE


BILL_Y = -1.84  # centre of the upper bill (its base is buried in the face)


def _upper_bill(p):
    """A short, broad wedge: thick where it meets the face (its top just under the eye), its top
    sloping down to a thinner, rounded tip that lifts a little."""
    u, v, w = p
    flat = math.copysign(abs(w) ** 0.55, w)  # squarer cross-section -> flatter top, crisper rim
    front = max(0.0, -v)
    x, y, z = u * 1.02, v * 0.42, flat * 0.15
    if w > 0:
        z += 0.05 * (1 - u * u) * w   # a very gentle dome on top
        z += 0.25 * _smooth(-1.0, 0.15, v) * flat   # wedge: about twice as thick at the face
    x *= 1 + 0.1 * front * front      # broad, rounded front edge (not a pointed oval)
    z += 0.1 * front * front          # tip lifts a little
    x *= 1 + 0.1 * max(0.0, v)        # wide base wrapping round the face
    z -= 0.06 * u * u                 # sides droop a touch
    return (x, BILL_Y + y, 3.24 + z)


def _upper_bill_pal(nz):
    return B_TOP if nz > 0.9 else B_BASE


def _lower_bill(p):
    u, v, w = p
    flat = math.copysign(abs(w) ** 0.65, w)
    front = max(0.0, -v)
    x, y, z = u * 0.92, v * 0.4, flat * 0.15
    x *= 1 + 0.22 * front * front
    z += 0.08 * front * front         # follows the upper bill's lift: only a thin ink line between
    z -= 0.05 * u * u
    return (x, BILL_Y + 0.1 + y, 3.03 + z)


def _lower_bill_pal(nz):
    return B_LOW_SH if nz < -0.3 else B_LOW


def _catmull(points, n=16):
    """Closed Catmull-Rom curve through `points` (2D tuples) -> dense list of points."""
    out = []
    k = len(points)
    for i in range(k):
        p0, p1, p2, p3 = (Vector(points[(i + j) % k]) for j in (-1, 0, 1, 2))
        for s in range(n):
            t = s / n
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    return out


# the wing's outline in side view (y back, z up), traced from the art: front edge bowed forward,
# top edge dipping between a soft front-top corner and the higher rear end
WING_C = Vector((0.85, 1.12))
WING_OUTLINE = [(-0.15, 1.94), (-0.52, 1.2), (-0.22, 0.45), (0.75, 0.27), (1.65, 0.42), (2.15, 1.05),
                (2.02, 1.78), (1.45, 1.82), (0.75, 1.62), (0.25, 1.74)]


def _wing_radius():
    """-> R(theta): distance from WING_C to the outline in direction theta (around +y toward +z)."""
    pts = _catmull(WING_OUTLINE, 24)
    pol = sorted((math.atan2(q.y - WING_C.y, q.x - WING_C.x), (q - WING_C).length) for q in pts)
    pol = [(pol[-1][0] - math.tau, pol[-1][1])] + pol + [(pol[0][0] + math.tau, pol[0][1])]

    def R(th):
        for (t0, r0), (t1, r1) in zip(pol, pol[1:]):
            if t0 <= th <= t1:
                return r0 + (r1 - r0) * (th - t0) / max(1e-9, t1 - t0)
        return pol[0][1]
    return R


def _wing(side, bvh):
    """A raised panel hugging the body's rear flank: its outer face stands out from the body's
    surface with a steep, rounded rim at the front and bottom and a gentler rise along the top.
    Built by ray-casting each panel point onto the body mesh (`bvh`); the sphere's poles sit on the
    X axis, so the outline is the equator - an even ring of vertices.
    Returns (shape fn, ink strokes): one short tapered stroke along the front of the bottom rim,
    where the art draws an ink accent the hull can't (the rim faces the camera there); the top edge's
    accent comes from the wing's own hull, and the front edge has no ink at all (shading only)."""
    R = _wing_radius()

    def surface_x(y, z):
        hit = bvh.ray_cast(Vector((side * 10.0, y, z)), Vector((-side, 0, 0)))[0]
        return abs(hit.x) if hit is not None else 1.2

    def panel(v, w):
        r = math.hypot(v, w)
        th = math.atan2(w, v)
        k = R(th) * min(1.0, r)
        return WING_C.x + k * math.cos(th), WING_C.y + k * math.sin(th)

    def fn(p):
        out, v, w = p                        # out: +1 = outer face, -1 = face buried in the body
        out *= side
        y, z = panel(v, w)
        xb = surface_x(y, z)
        if out > 0:
            top = _smooth(0.1, 0.8, w)       # gentler rise along the top edge
            k = 0.32 + 0.5 * top
            rear = _smooth(-0.2, 1.0, v)     # the raised rim is at the front; the rear blends in
            x = xb + 0.26 * (1 - 0.55 * rear) * out ** k
        else:
            x = xb - 0.16 * (-out) ** 0.7
        return (side * x, y, z)

    strokes = []
    for th0, th1 in ((-2.3, -1.65),):                  # the front part of the bottom edge
        pts = []
        for i in range(6):
            th = th0 + (th1 - th0) * i / 5
            y, z = panel(math.cos(th) * 1.02, math.sin(th) * 1.02)
            pts.append((side * (surface_x(y, z) + 0.035), y, z))
        strokes.append(pts)
    return fn, strokes


def _surface(center, radius, scale, az, el):
    """Point on an ellipsoid head at azimuth `az` (0 = front -Y, + toward +X) and elevation `el`."""
    d = Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))
    return center + Vector((d.x * scale[0], d.y * scale[1], d.z * scale[2])) * radius, d


def build():
    body = _blob(_body, _body_pal, seg=36, rings=22, name="body", cuts=(-0.55, -0.12, 0.82),
                 dense=(TAIL_DIR, 0.55, 0.9))
    p = [body,
         _blob(_head, _head_pal, seg=28, rings=16, name="head", cuts=(-0.6, 0.8)),
         _blob(_upper_bill, _upper_bill_pal, seg=28, rings=14, name="bill_up", cuts=(0.9,)),
         _blob(_lower_bill, _lower_bill_pal, seg=20, rings=10, name="bill_low", cuts=(-0.3,))]
    me = body.mesh
    bvh = BVHTree.FromPolygons([v.co.copy() for v in me.vertices], [tuple(f.vertices) for f in me.polygons])
    for side in (-1, 1):
        wing, strokes = _wing(side, bvh)
        p.append(_blob(wing, lambda nz: D_DEEP if nz < -0.45 else D_SHADE, seg=28, rings=12, name="wing",
                       cuts=(-0.45,), pole="x"))
        for pts in strokes:
            radii = [0.2, 0.75, 1.0, 1.0, 0.75, 0.2]   # brush-stroke taper
            p.append(K.tube(INK, pts, radius=0.05, radii=radii, res=3, bevel_res=1, outline=False,
                            name="wing_ink"))
        az, el = side * 0.74, 0.23
        pos, d = _surface(HEAD_C, HEAD_R, HEAD_S, az, el)
        eye_m = M(pos - d * 0.04, rot=(-el, 0, az), scale=(0.215, 0.12, 0.22))
        p.append(K.sphere(EYE, 1.0, eye_m, seg=12, rings=8, outline=False, name="eye"))
        # glint: up and toward the front of the eye
        g = pos + d * 0.05 + Vector((-side * 0.045, -0.04, 0.08))
        p.append(K.sphere(K.WHITE, 0.045, M(g), seg=8, rings=5, outline=False, name="glint"))
    body, outline = K.finish(p, "Duck", outline_width=0.09)
    _camera_only_outline(outline)
    return [body, outline] + K.markers("Duck")
