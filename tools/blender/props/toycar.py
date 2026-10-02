"""
props/toycar.py - the ToyCar prop (ReplicatedStorage.MapMeshes.ToyCar): a chunky cartoon toy race
car left on the bedroom floor. See props/__init__.py for the conventions every prop follows.

The nose points FRONT (-Y). The body is one closed superquadric loft (a UV sphere whose poles sit
on the Y axis, mapped through per-station width / roof / floor profiles): a low wedge nose rising
to fat side pods between the axles and a raised rear deck, a shallow cockpit dip on top. Colour
regions are cut into that surface along smooth iso-lines (tone bands by the surface normal, a
wide cream racing stripe by x and z), so every border is a clean curve. On top: the open cockpit
(a dark opening with a rim, a seat back and a little steering wheel), a curved windscreen with a
glint, a spoiler on two struts with end plates, twin exhaust tips, a dark air intake on the nose,
and a blue roundel with a white racing number on each side pod. Four big black tyres (bigger at
the back) with grey hubs, each one lathe mesh (closed, so its outline hull is watertight).
"""
import math
import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "ToyCar"

RED = (hexcol("toycar_red_light", "#FF6352"), hexcol("toycar_red", "#E33A33"),
       hexcol("toycar_red_dark", "#B0282B"), hexcol("toycar_red_deep", "#841D27"))
CREAM = (hexcol("toycar_cream_light", "#FFF6DC"), hexcol("toycar_cream", "#F6E2B4"),
         hexcol("toycar_cream_dark", "#D8BC88"))
TYRE = (hexcol("toycar_tyre_light", "#4F4A5C"), hexcol("toycar_tyre", "#2F2B39"), hexcol("toycar_tyre_dark", "#1D1A25"))
HUB = (hexcol("toycar_hub_light", "#E4E7EF"), hexcol("toycar_hub", "#B6BCCA"), hexcol("toycar_hub_dark", "#848B9E"))
HUB_CAP = hexcol("toycar_hub_cap", "#D3D8E2")
GLASS = (hexcol("toycar_glass_light", "#DDF4FF"), hexcol("toycar_glass", "#A6DBF3"))
GLINT = hexcol("toycar_glint", "#FFFFFF")
HOLE = hexcol("toycar_cockpit", "#2A2236")
SEAT = (hexcol("toycar_seat_light", "#4A4258"), hexcol("toycar_seat", "#363044"))
INK = hexcol("toycar_ink", "#241A2E")
ROUNDEL = (hexcol("toycar_roundel_light", "#5F8CEB"), hexcol("toycar_roundel", "#3E6BD6"))
NUMBER = hexcol("toycar_number", "#FFFFFF")
METAL = (hexcol("toycar_metal_light", "#E2E5EC"), hexcol("toycar_metal", "#A8AEBC"))

TONE_CUTS = (-0.5, 0.58)    # normal z: deep shade below, lit above
SHADE_CUT = -0.08           # ... and the plain shade band between
STRIPE_W = 0.36             # cream stripe half-width
STRIPE_Z = 1.0              # the stripe covers the body above this height (over the nose too)

# body stations along Y (nose at -Y): (y, half width, floor z, roof z)
STATIONS = [(-3.4, 1.1, 0.6, 1.36), (-2.9, 1.2, 0.55, 1.52), (-2.2, 1.3, 0.52, 1.68), (-1.4, 1.46, 0.5, 1.84),
            (-0.6, 1.56, 0.5, 1.96), (0.5, 1.58, 0.5, 2.02), (1.4, 1.5, 0.5, 2.1), (2.2, 1.42, 0.52, 2.16),
            (2.9, 1.38, 0.56, 2.14), (3.35, 1.36, 0.6, 2.1)]
L_NOSE, L_TAIL = 3.4, 3.35
COCKPIT_C = Vector((0.0, 0.2))   # (x, y) centre of the cockpit opening
COCKPIT_A = (0.7, 0.92)          # its half-width, half-length
FRONT_AXLE, REAR_AXLE = -2.15, 2.05
FRONT_WHEEL = (0.92, 0.74, 1.7)  # radius, width, x of the centre
REAR_WHEEL = (1.06, 0.9, 1.74)


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


def _station(y):
    """Interpolated (half width, floor, roof) at y (Catmull-Rom through STATIONS)."""
    st = STATIONS
    if y <= st[0][0]:
        return st[0][1:]
    if y >= st[-1][0]:
        return st[-1][1:]
    i = max(k for k in range(len(st) - 1) if st[k][0] <= y)
    p0, p1, p2, p3 = st[max(i - 1, 0)], st[i], st[i + 1], st[min(i + 2, len(st) - 1)]
    t = (y - p1[0]) / (p2[0] - p1[0])
    out = []
    for j in (1, 2, 3):
        a, b, c, d = p0[j], p1[j], p2[j], p3[j]
        out.append(0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t ** 3))
    return out


def _body_point(q):
    """Unit sphere point (pole on Y) -> body surface: a superquadric whose cross-section at each
    station is a rounded rectangle spanning that station's width, floor and roof."""
    u, v, w = q
    nose = v < 0
    e1 = 0.42 if nose else 0.3          # rounder nose, squarer tail
    y = _spow(v, e1) * (L_NOSE if nose else L_TAIL)
    r = math.sqrt(max(0.0, u * u + w * w))
    rr = r ** e1
    if r > 1e-9:
        cu, cw = u / r, w / r
    else:
        cu, cw = 0.0, 0.0
    e2 = 0.55 if w > 0 else 0.35        # rounded shoulders, flatter, squarer floor
    hw, z0, z1 = _station(y)
    x = hw * rr * _spow(cu, e2)
    zc, hh = (z0 + z1) / 2, (z1 - z0) / 2
    z = zc + hh * rr * _spow(cw, e2)
    # the cockpit: a shallow dip in the roof round the opening
    if w > 0:
        d = ((x - COCKPIT_C.x) / (COCKPIT_A[0] + 0.25)) ** 2 + ((y - COCKPIT_C.y) / (COCKPIT_A[1] + 0.25)) ** 2
        z -= 0.16 * _smooth(1.0, 0.45, d) * _smooth(0.0, 0.6, cw)
    return Vector((x, y, z))


def _body():
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=22, v_segments=18, radius=1.0)
    for vt in bm.verts:
        x, y, z = vt.co
        vt.co = _body_point(Vector((y, z, x)))  # cyclic axis swap (keeps the winding): pole -> +-Y
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()
    nz = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, nz, (TONE_CUTS[0], SHADE_CUT, TONE_CUTS[1]))
    xs = {v: v.co.x for v in bm.verts}
    _iso_cut(bm, xs, (-STRIPE_W, STRIPE_W))
    zs = {v: v.co.z for v in bm.verts}
    _iso_cut(bm, zs, (STRIPE_Z,))
    bm.normal_update()
    pal = []
    for f in bm.faces:
        c = f.calc_center_median()
        n = sum(v.normal.z for v in f.verts) / len(f.verts)
        if abs(c.x) < STRIPE_W and c.z > STRIPE_Z:
            pal.append(CREAM[0] if n > TONE_CUTS[1] else (CREAM[1] if n > SHADE_CUT else CREAM[2]))
        else:
            pal.append(RED[0] if n > TONE_CUTS[1] else RED[1] if n > SHADE_CUT else RED[2] if n > TONE_CUTS[0] else RED[3])
    return K.Piece(K._bm_to_mesh(bm, "body"), pal, True, True, "body")


def _lathe(profile, seg, mat, colour, name, outline=True):
    """A closed surface of revolution round local +X: profile = [(x, r, tag)], from r = 0 on one
    side round to r = 0 on the other. colour(tag, normal) -> palette index (normal in world space)."""
    bm = bmesh.new()
    rings, tags = [], []
    for x, r, _t in profile:
        if r <= 1e-9:
            rings.append([bm.verts.new((x, 0, 0))])
        else:
            rings.append([bm.verts.new((x, r * math.cos(a), r * math.sin(a))) for a in (j / seg * math.tau for j in range(seg))])
    for i in range(len(rings) - 1):
        a, b, tag = rings[i], rings[i + 1], profile[i][2]
        if len(a) == 1 or len(b) == 1:
            ring = b if len(a) == 1 else a
            ctr = a[0] if len(a) == 1 else b[0]
            for j in range(seg):
                k = (j + 1) % seg
                bm.faces.new((ctr, ring[j], ring[k]))
                tags.append(tag)
            continue
        for j in range(seg):
            k = (j + 1) % seg
            bm.faces.new((a[j], a[k], b[k], b[j]))
            tags.append(tag)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    bm.normal_update()
    pal = [colour(t, f.normal) for f, t in zip(bm.faces, tags)]
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline, True, name)


def _wheel(y, spec, side):
    rad, wid, xc = spec
    h = wid / 2
    rim = rad * 0.6
    # local +X points out of the car; from the inner side round the tread to the hub on the outer face
    prof = [(-h + 0.04, 0.0, "tyre"), (-h, rim, "tyre"), (-h + 0.04, rad * 0.9, "tyre"), (-h + 0.17, rad, "tyre"),
            (h - 0.17, rad, "tyre"), (h - 0.04, rad * 0.9, "tyre"), (h, rim * 1.1, "lip"), (h - 0.06, rim, "hub"),
            (h - 0.02, rim * 0.45, "cap"), (h + 0.04, 0.0, None)]
    mat = M((side * xc, y, rad), rot=(0, 0, 0 if side > 0 else math.pi))

    def colour(tag, n):
        if tag in ("tyre", "lip"):
            return TYRE[0] if n.z > 0.62 else (TYRE[2] if n.z < -0.4 else TYRE[1])
        if tag == "hub":
            return HUB[0] if n.z > 0.62 else (HUB[2] if n.z < -0.4 else HUB[1])
        return HUB_CAP
    return _lathe(prof, 18, mat, colour, "wheel")


def _fender(y, spec, side):
    """A chunky mudguard arching over the top of a wheel (the tyre still shows front and back): a
    rounded-rectangle section swept round the axle, thinner at the ends, its inner edge sunk into
    the body side."""
    rad, wid, xc = spec
    ra = rad + 0.17
    t = 0.11                    # radial half thickness
    hx = wid / 2 + 0.06         # half width across
    xm = side * (xc - 0.03)
    n_arc, n_sec = 9, 8
    a0, a1 = math.radians(-78), math.radians(66)
    bm = bmesh.new()
    rings = []
    for i in range(n_arc + 1):
        th = a0 + (a1 - a0) * i / n_arc
        end = min(i, n_arc - i) / n_arc
        k = 0.62 + 0.38 * _smooth(0.0, 0.3, end)          # the ends taper
        radial = Vector((0, -math.sin(th), math.cos(th)))
        c = Vector((xm, y, rad)) + radial * ra
        ring = []
        for j in range(n_sec):
            a = j / n_sec * math.tau
            cx, cr = _spow(math.cos(a), 0.45), _spow(math.sin(a), 0.45)
            ring.append(bm.verts.new(c + Vector((cx * hx * (0.85 + 0.15 * k), 0, 0)) + radial * (cr * t * k)))
        rings.append(ring)
    for i in range(n_arc):
        for j in range(n_sec):
            k = (j + 1) % n_sec
            bm.faces.new((rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]))
    bm.faces.new(rings[0])
    bm.faces.new(rings[-1][::-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()
    pal = []
    for f in bm.faces:
        nz = f.normal.z
        pal.append(RED[0] if nz > TONE_CUTS[1] else RED[1] if nz > SHADE_CUT else RED[2] if nz > TONE_CUTS[0] else RED[3])
    pc = K.Piece(K._bm_to_mesh(bm, "fender"), pal, True, True, "fender")
    pc.flat_faces = [len(pal) - 2, len(pal) - 1]
    return pc


def _bvh(piece):
    me = piece.mesh
    return BVHTree.FromPolygons([v.co.copy() for v in me.vertices], [tuple(p.vertices) for p in me.polygons])


def _patch(bvh, origin, along, du, dv, shape, lift, pal, name, rings=4, seg=28, outline=False, inner=0.0):
    """A thin sheet hugging the body: points origin + du * a + dv * b for (a, b) in `shape(r, t)`
    (r 0..1 from the centre, t angle) are projected along `along` onto the mesh, lifted `lift` back
    toward the viewer. `inner` > 0 leaves a hole (a ring from r = inner to 1)."""
    bm = bmesh.new()

    def vert(r, t):
        a, b = shape(r, t)
        o = origin + du * a + dv * b - along * 6.0
        hit = bvh.ray_cast(o, along)[0]
        p = hit if hit is not None else origin + du * a + dv * b
        return bm.verts.new(p - along * lift)
    if inner > 0:
        ring = [[vert(inner + (1 - inner) * i / rings, j / seg * math.tau) for j in range(seg)] for i in range(rings + 1)]
    else:
        mid = vert(0.0, 0.0)
        ring = [[vert(i / rings, j / seg * math.tau) for j in range(seg)] for i in range(1, rings + 1)]
        for j in range(seg):
            bm.faces.new((mid, ring[0][(j + 1) % seg], ring[0][j]))
    for i in range(len(ring) - 1):
        for j in range(seg):
            bm.faces.new((ring[i][j], ring[i][(j + 1) % seg], ring[i + 1][(j + 1) % seg], ring[i + 1][j]))
    bm.normal_update()
    if sum(f.normal.dot(along) for f in bm.faces) > 0:  # face the viewer (against `along`)
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline, True, name)


def _poly_decal(bvh, origin, along, du, dv, pts, lift, pal, name):
    """A flat polygon (2D `pts`, CCW in (du, dv)) projected onto the mesh along `along`."""
    bm = bmesh.new()
    vs = []
    for a, b in pts:
        o = origin + du * a + dv * b - along * 6.0
        hit = bvh.ray_cast(o, along)[0]
        p = hit if hit is not None else origin + du * a + dv * b
        vs.append(bm.verts.new(p - along * lift))
    bm.faces.new(vs)
    bm.normal_update()
    if sum(f.normal.dot(along) for f in bm.faces) > 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    return K.Piece(K._bm_to_mesh(bm, name), pal, False, False, name)


def _loop_tube(points, radius, sides, pal, name, up=Vector((0, 0, 1)), outline=True):
    """A closed tube (ring) through `points` (a closed loop)."""
    bm = bmesh.new()
    n = len(points)
    rings = []
    for i in range(n):
        t = (Vector(points[(i + 1) % n]) - Vector(points[i - 1])).normalized()
        nn = (up - t * up.dot(t)).normalized()
        b = t.cross(nn)
        c = Vector(points[i])
        rings.append([bm.verts.new(c + (nn * math.cos(a) + b * math.sin(a)) * radius)
                      for a in (j / sides * math.tau for j in range(sides))])
    for i in range(n):
        a, b = rings[i], rings[(i + 1) % n]
        for j in range(sides):
            k = (j + 1) % sides
            bm.faces.new((a[j], b[j], b[k], a[k]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline, True, name)


SEVEN = [(-0.36, 0.5), (0.4, 0.5), (0.4, 0.27), (0.04, -0.5), (-0.27, -0.5), (0.1, 0.25), (-0.36, 0.25)]


def _windscreen():
    """A curved, back-tilted screen in front of the cockpit: a thin slab on a cylinder arc."""
    bm = bmesh.new()
    nu, nv = 8, 2
    R, half = 1.15, 0.62           # arc radius, half angle
    y0 = COCKPIT_C.y - COCKPIT_A[1] + 0.12
    base_z = 1.72
    hgt, tilt, th = 0.55, 0.55, 0.05
    grid = {}
    for side in (0, 1):
        rr = R + (th if side else 0.0)
        for i in range(nu + 1):
            a = -half + 2 * half * i / nu
            for j in range(nv + 1):
                s = j / nv
                hh = hgt * s * (1 - 0.18 * (2 * i / nu - 1) ** 2)    # lower at the ends
                x = rr * math.sin(a) * (1 - 0.06 * s)
                yy = y0 + R - rr * math.cos(a) + hh * math.sin(tilt)
                grid[side, i, j] = bm.verts.new((x, yy, base_z + hh * math.cos(tilt)))
    faces, pal = [], []
    for i in range(nu):
        for j in range(nv):
            faces.append(bm.faces.new((grid[0, i, j], grid[0, i + 1, j], grid[0, i + 1, j + 1], grid[0, i, j + 1])))
            faces.append(bm.faces.new((grid[1, i, j], grid[1, i, j + 1], grid[1, i + 1, j + 1], grid[1, i + 1, j])))
    for i in range(nu):   # top and bottom edges
        for j in (0, nv):
            q = (grid[0, i, j], grid[1, i, j], grid[1, i + 1, j], grid[0, i + 1, j])
            faces.append(bm.faces.new(q if j == 0 else q[::-1]))
    for i in (0, nu):     # side edges
        for j in range(nv):
            q = (grid[0, i, j], grid[0, i, j + 1], grid[1, i, j + 1], grid[1, i, j])
            faces.append(bm.faces.new(q if i == 0 else q[::-1]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()
    for f in bm.faces:
        pal.append(GLASS[0] if f.normal.z > 0.75 else GLASS[1])
    scr = K.Piece(K._bm_to_mesh(bm, "screen"), pal, True, True, "screen")
    # glint: a slanted white bar on the front face, toward the left
    g = []
    for a0, s0, a1, s1 in ((-0.38, 0.2, -0.2, 0.85), (-0.1, 0.25, -0.0, 0.6)):
        pts = []
        for a, s in ((a0, s0), (a0 + 0.1, s0), (a1 + 0.1, s1), (a1, s1)):
            rr = R - 0.012
            hh = hgt * s
            pts.append(Vector((rr * math.sin(a), y0 + R - rr * math.cos(a) + hh * math.sin(tilt), base_z + hh * math.cos(tilt))))
        bmg = bmesh.new()
        vs = [bmg.verts.new(p) for p in pts]
        fg = bmg.faces.new(vs)
        bmg.normal_update()
        if fg.normal.y > 0:
            bmesh.ops.reverse_faces(bmg, faces=bmg.faces)
        g.append(K.Piece(K._bm_to_mesh(bmg, "glint"), GLINT, False, False, "glint"))
    return [scr] + g


def _spoiler():
    p = []
    yw, zw = 2.9, 3.05
    wing = K.rounded_box(RED[1], (3.5, 0.95, 0.17), M((0, yw, zw), rot=(-0.12, 0, 0)), bevel=0.07, segments=2, name="wing")
    K.recolor_by(wing, lambda c, cur: RED[0] if c.z > zw + 0.05 else (RED[2] if c.z < zw - 0.05 else RED[1]))
    p.append(wing)
    for s in (-1, 1):
        plate = K.rounded_box(RED[1], (0.12, 0.9, 0.44), M((s * 1.8, yw + 0.02, zw - 0.05)), bevel=0.05, segments=1,
                              name="plate")
        K.recolor_by(plate, lambda c, cur: RED[0] if c.z > zw + 0.15 else RED[2] if c.z < zw - 0.28 else RED[1])
        p.append(plate)
        strut = K.rounded_box(TYRE[1], (0.16, 0.38, 1.0), M((s * 0.7, yw - 0.02, zw - 0.55), rot=(0.12, 0, 0)), bevel=0.05,
                              segments=1, name="strut")
        p.append(strut)
    # cream stripe on the wing, continuing the body stripe
    stripe = K.rounded_box(CREAM[0], (STRIPE_W * 2, 0.97, 0.02), M((0, yw, zw + 0.085), rot=(-0.12, 0, 0)), bevel=0.008,
                           segments=1, outline=False, name="wing_stripe")
    p.append(stripe)
    return p


def build():
    body = _body()
    bvh = _bvh(body)
    p = [body]
    for side in (-1, 1):
        for ya, spec in ((FRONT_AXLE, FRONT_WHEEL), (REAR_AXLE, REAR_WHEEL)):
            p.append(_wheel(ya, spec, side))
            p.append(_fender(ya, spec, side))
    down = Vector((0, 0, -1))
    ex, ey = Vector((1, 0, 0)), Vector((0, 1, 0))
    top = Vector((COCKPIT_C.x, COCKPIT_C.y, 3.0))

    def oval(a, b):
        return lambda r, t: (a * r * math.cos(t), b * r * math.sin(t))
    # cockpit: dark opening, a rim round it
    p.append(_patch(bvh, top, down, ex, ey, oval(*COCKPIT_A), 0.015, HOLE, "cockpit", rings=2, seg=22))
    rim = []
    for j in range(22):
        t = j / 22 * math.tau
        o = Vector((COCKPIT_C.x + (COCKPIT_A[0] + 0.03) * math.cos(t), COCKPIT_C.y + (COCKPIT_A[1] + 0.03) * math.sin(t), 3.0))
        hit = bvh.ray_cast(o, down)[0]
        rim.append(tuple(hit + Vector((0, 0, 0.03))))
    p.append(_loop_tube(rim, 0.07, 4, RED[3], "rim", outline=False))
    # seat back and steering wheel inside the opening
    sy = COCKPIT_C.y + COCKPIT_A[1] * 0.55
    seat_z = bvh.ray_cast(Vector((0, sy, 3.0)), down)[0].z
    seat = K.rounded_box(SEAT[1], (1.0, 0.3, 0.55), M((0, sy, seat_z + 0.12), rot=(-0.25, 0, 0)), bevel=0.11, segments=2,
                         name="seat")
    K.recolor_by(seat, lambda c, cur: SEAT[0] if c.z > seat_z + 0.3 else SEAT[1])
    p.append(seat)
    wy = COCKPIT_C.y - COCKPIT_A[1] * 0.35
    wz = bvh.ray_cast(Vector((0, wy, 3.0)), down)[0].z
    p.append(K.torus(INK, 0.24, 0.05, M((0, wy, wz + 0.32), rot=(-1.05, 0, 0)), seg=12, mseg=4, outline=False, name="steer"))
    p.append(K.cylinder(INK, 0.05, 0.4, M((0, wy + 0.12, wz + 0.15), rot=(-1.05, 0, 0)), seg=6, outline=False, name="column"))
    p += _windscreen()
    p += _spoiler()
    # twin exhaust tips under the tail
    for s in (-1, 1):
        ez = 0.86
        p.append(_lathe([(-0.3, 0.0, "m"), (-0.3, 0.13, "m"), (0.3, 0.13, "m"), (0.3, 0.085, "in"), (0.22, 0.085, "in"),
                         (0.22, 0.0, None)], 8, M((s * 0.62, 3.45, ez), rot=(0, 0, math.pi / 2)),
                        lambda tag, n: HOLE if tag == "in" else (METAL[0] if n.z > 0.5 else METAL[1]), "exhaust"))
    p[-1].mesh.transform(Matrix.Translation((0, -0.1, 0)))
    # air intake on the nose
    front = Vector((0, -6.0, 0.98))
    p.append(_patch(bvh, front + Vector((0, 6.0, 0)), ey, ex, Vector((0, 0, 1)), oval(0.55, 0.17), 0.012, HOLE, "intake",
                    rings=2, seg=20))
    # racing roundels on the side pods: white ring, blue disc, white number
    for s in (-1, 1):
        along = Vector((-s, 0, 0))
        du = Vector((0, s, 0))          # the number's right: toward the tail on the +X side
        dv = Vector((0, 0, 1))
        o = Vector((s * 2.5, -0.05, 1.18))
        p.append(_patch(bvh, o, along, du, dv, oval(0.53, 0.53), 0.045, NUMBER, "roundel_ring", rings=1, seg=22, inner=0.78))
        p.append(_patch(bvh, o, along, du, dv, oval(0.43, 0.43), 0.045, ROUNDEL[1], "roundel", rings=2, seg=22))
        p.append(_poly_decal(bvh, o, along, du, dv, [(a * 0.52, b * 0.55) for a, b in SEVEN], 0.06, NUMBER, "number"))
    for pc in p:   # centre the footprint on the origin (the spoiler and exhausts reach further back than the nose)
        pc.mesh.transform(Matrix.Translation((0, -0.17, 0)))
    car, outline = K.finish(p, NAME, outline_width=0.075)
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission", "visible_volume_scatter"):
        if hasattr(outline, attr):  # preview only: the hull must not block light (it doesn't in Roblox)
            setattr(outline, attr, False)
    return [car, outline] + K.markers(NAME)
