"""
sockfeat_a.py - signature features for Tubolino, AnkleBiter, CrustyCrew, GymGary, Argylo, ToeToe, Sockrates.

Each feature builder takes the SockCtx `c` built by socks.py (body shape, eye/mouth positions,
surface helpers, colours) and returns a list of sockkit Pieces added on top of the shared body.
Only rely on SockCtx fields - never hard-code body dimensions - so the body can be reshaped without
breaking the features. Colour names must be prefixed with the type id (first registration wins).

Matching docs/concept/sock_character_sheet.png (colours sampled from it with Pillow; the sheet
draws the LEFT sock, foot to the viewer's left, so compare sock:<Type>:L):
  Tubolino   - two equal blue stripes, the lower one behind the upper half of the eyes, and a toe
               band (SPEC_OVERRIDES); sad eyes: a lid in the leg's own colour (blue where a stripe
               runs behind it) hides the top-outer part of each eye, ending exactly at the ink
               rim, and an ink line along the lid edge rises into a worried brow at the inner end
               and flicks out past the rim at the outer end; a frown.
  AnkleBiter - the shared short body; the shared "fangs" grin redrawn a little higher (closer under
               the eyes, like the sheet).
  Argylo     - an argyle band from the cuff down to just above the heel patch: 4 rows of yellow
               diamonds touching tip to tip, 10 round the leg, thin dark-brown overcheck lines on
               every other diamond edge; a gold monocle (inked on both edges, an opaque light-blue
               lens with one flat diagonal glint) over the heel-side eye, a knob at 3 o'clock and a
               thin chain hanging from it in one curve, bowing out, to a clip loop at the leg's edge.
  Sockrates  - a laurel wreath: a big diagonal sprig of plump two-tone leaves on the heel side
               (standing off the leg where it passes the side, so its end leaves stick out past the
               outline at eye-top height), three leaves fanning out past the toe-side outline, both
               branches meeting low at the back; nothing above the rim. Leaves are thin blades
               inked by a hidden smaller 'carrier' whose outline hull ends just past the leaf. A
               big grey cut-out beard inked all round (lobed tufts, pointed tip) with a cream
               two-lobed lip under a peaked moustache, riding over the toga where they overlap; a
               thin toga pinned by a gold brooch on the heel-side shoulder (the top edge peaks at
               the brooch and sweeps down across the front to the toe side), parting behind the
               brooch over a strip of leg, flaring a little at the hem over the bare toe, with
               blue-grey fold lines fanning from under the brooch.
Designed in the same style (no art):
  CrustyCrew - dried rigid: two broad, angular crumple folds (body-coloured upper side, darker fold
               shade under the ridge) that kink the outline at the sides, a stiff dog-ear of the rim
               rolled over the lip and folded out on the heel side, three big flat dried patches
               (by the toe-side eye, on the instep, on the back) with broken ink borders and a few
               crumbs, and half-lidded, unimpressed eyes over the flat mouth.
  GymGary    - a red terry sweatband with a white stripe hugging the top, a strip of mint under it
               (face lowered in SPEC_OVERRIDES), sweat drops on the forehead under the band, down the
               toe-side cheek and on the back.
  ToeToe     - a hotter pink than AnkleBiter; the foot ends in five fat toes in the darker toe
               colour, side by side across the foot (big toe at the back, little toe toward the
               viewer, like a right foot pointing +X), pitched up level, the tips stepping back and
               down from the big toe so each shows its own rounded end; the hulls ink the V gaps.
Decals (diamonds, lines, patches) sit >= 0.01 off what is under them; flat pads get an ink plate
under them instead of an outline hull (a hull on a flat pad leaves a body-coloured gap). Lines
that lie on a surface are flat ribbons (cheap); every sock stays under 8,000 triangles.
"""
import math
import random
import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import delaunay_2d_cdt
import sockkit as K
from sockkit import M, color, hexcol  # noqa: F401
from socks import (C_BLUEBOLT, C_CASH, C_DARK, C_GOLD, C_GOLD2, C_GREEN, C_GREY, C_MAGENTA,  # noqa: F401
                   C_PINKMOUTH, C_RED, C_SILVER, C_SILVER2, C_STINK, C_TONGUE, C_WICKER, C_WICKER2)

INK = 0.032          # half width of a drawn ink line (same weight as the shared face's mouths)
OUTLINE_W = 0.06     # the outline hull width socks.build_sock passes to sockkit.finish


# ------------------------------------------------------------------ small geometry helpers
def _lerp(a, b, t):
    return a + (b - a) * t


def _smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def _wrap(a):
    return (a + math.pi) % (2 * math.pi) - math.pi


def _piece(bm, pal, outline=False, smooth=True, name="part"):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pal, outline, smooth, name)


def _catmull(points, samples=6):
    """Centripetal Catmull-Rom through 3D points -> dense list of Vectors (ends kept)."""
    P = [Vector(p) for p in points]
    if len(P) < 3:
        return [P[0].lerp(P[-1], i / (samples * 2)) for i in range(samples * 2 + 1)]
    pts = [P[0] * 2 - P[1]] + P + [P[-1] * 2 - P[-2]]
    out = [P[0].copy()]
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        t0 = 0.0
        t1 = t0 + max((p1 - p0).length ** 0.5, 1e-4)
        t2 = t1 + max((p2 - p1).length ** 0.5, 1e-4)
        t3 = t2 + max((p3 - p2).length ** 0.5, 1e-4)
        for k in range(1, samples + 1):
            t = t1 + (t2 - t1) * k / samples
            a1 = p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
            a2 = p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
            a3 = p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
            b1 = a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
            b2 = a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
            out.append(b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1)))
    return out


def _frame(n):
    """Two unit tangents (t1 roughly horizontal, t2 roughly up) for a surface normal n."""
    n = Vector(n).normalized()
    up = Vector((0.0, 0.0, 1.0))
    t1 = up.cross(n)
    if t1.length < 1e-4:
        t1 = Vector((1.0, 0.0, 0.0))
    t1.normalize()
    t2 = n.cross(t1).normalized()
    return t1, t2


def _ink(pts, nrms, radius=INK, flat=0.5, seg=6, samples=4, pal=None, taper=1.0, name="ink"):
    """A drawn ink stroke through 3D points (nrms = surface normals there): a flat elliptical tube
    with rounded ends; taper < 1 thins both ends like a brush stroke."""
    pal = K.BLACK if pal is None else pal
    P = _catmull(pts, samples)
    N = _catmull(nrms, samples)
    m = len(P)
    rads = [radius * _lerp(taper, 1.0, math.sin(math.pi * i / max(m - 1, 1)) ** 0.7) for i in range(m)]
    T = [(P[min(i + 1, m - 1)] - P[max(i - 1, 0)]).normalized() for i in range(m)]
    bm = bmesh.new()

    def ring(ctr, t, nn, rad):
        nn = (nn - t * nn.dot(t)).normalized()
        b = t.cross(nn)
        return [bm.verts.new(ctr + b * (rad * math.cos(2 * math.pi * k / seg)) + nn * (rad * flat * math.sin(2 * math.pi * k / seg)))
                for k in range(seg)]

    r0, r1 = rads[0], rads[-1]
    rings = [ring(P[0] - T[0] * r0 * 0.6, T[0], N[0], r0 * 0.78)]
    rings += [ring(P[i], T[i], N[i], rads[i]) for i in range(m)]
    rings.append(ring(P[-1] + T[-1] * r1 * 0.6, T[-1], N[-1], r1 * 0.78))
    tip0 = bm.verts.new(P[0] - T[0] * r0 * 0.95)
    tip1 = bm.verts.new(P[-1] + T[-1] * r1 * 0.95)
    for k in range(seg):
        k2 = (k + 1) % seg
        bm.faces.new((tip0, rings[0][k2], rings[0][k]))
        bm.faces.new((tip1, rings[-1][k], rings[-1][k2]))
    for ra, rb in zip(rings, rings[1:]):
        for k in range(seg):
            k2 = (k + 1) % seg
            bm.faces.new((ra[k], rb[k], rb[k2], ra[k2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _piece(bm, pal, False, True, name)


def _ribbon(pts, nrms, half, pal=None, taper=0.3, samples=3, name="ribbon"):
    """A drawn line as a flat strip lying on a surface (nrms = the surface normals at pts): `half`
    wide each side in the middle, `taper` * half at the pointed ends. Two triangles per sample, so
    it is far cheaper than a tube for decal lines (folds, edges, moustaches)."""
    pal = K.BLACK if pal is None else pal
    P = _catmull(pts, samples)
    N = _catmull(nrms, samples)
    m = len(P)
    bm = bmesh.new()
    Lv, Rv = [], []
    for i in range(m):
        t = (P[min(i + 1, m - 1)] - P[max(i - 1, 0)]).normalized()
        n = N[i].normalized()
        b = n.cross(t).normalized()
        w = half * _lerp(taper, 1.0, math.sin(math.pi * i / max(m - 1, 1)) ** 0.6)
        Lv.append(bm.verts.new(P[i] + b * w))
        Rv.append(bm.verts.new(P[i] - b * w))
    t0, t1 = (P[1] - P[0]).normalized(), (P[-1] - P[-2]).normalized()
    a = bm.verts.new(P[0] - t0 * half * max(taper, 0.3))
    e = bm.verts.new(P[-1] + t1 * half * max(taper, 0.3))
    faces = [bm.faces.new((a, Rv[0], Lv[0])), bm.faces.new((e, Lv[-1], Rv[-1]))]
    for i in range(m - 1):
        faces.append(bm.faces.new((Lv[i], Rv[i], Rv[i + 1], Lv[i + 1])))
    bm.normal_update()
    for f in faces:
        k = min(range(m), key=lambda i: (P[i] - f.calc_center_median()).length)
        if f.normal.dot(N[k]) < 0:
            f.normal_flip()
    return _piece(bm, pal, False, True, name)


def _orient(bm, inside):
    """A shell built with consistent winding: turn ALL its faces so that most of the area faces
    away from inside(face_centre) (a point behind the face, inside the body)."""
    bm.normal_update()
    vote = 0.0
    for f in bm.faces:
        cen = f.calc_center_median()
        vote += f.calc_area() * (1 if f.normal.dot(cen - inside(cen)) > 0 else -1)
    if vote < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    bm.normal_update()


def _grid_shell(rows, inside, closed_u=False, pal=None, name="shell", outline=False, smooth=True):
    """Quad shell through a grid of points rows[i][j] (i along v, j along u); pal(i, j) -> colour
    of the quad starting at (i, j) or an int. Faces turned away from inside(p)."""
    bm = bmesh.new()
    V = [[bm.verts.new(p) for p in row] for row in rows]
    pals = []
    nu = len(rows[0])
    for i in range(len(V) - 1):
        for j in range(nu if closed_u else nu - 1):
            j2 = (j + 1) % nu
            bm.faces.new((V[i][j], V[i + 1][j], V[i + 1][j2], V[i][j2]))
            pals.append(pal(i, j) if callable(pal) else pal)
    _orient(bm, inside)
    return _piece(bm, pals, outline, smooth, name)


# ------------------------------------------------------------------ surface helpers (all built from SockCtx ray casts)
def _leg_map(c):
    """(s, z, lift) -> point on the leg: s = arc length from the front (+ toward +X)."""
    def to3d(s, z, lift):
        r = max(c.radius_at(z), 0.2)
        return c.surface(s / r, z, lift)[0]
    return to3d


def _axis_inside(p):
    return Vector((0.0, 0.0, p.z))


def _skeleton_origin(c, p):
    """A point inside the body near p (on the leg axis, the foot axis or in the heel), to cast from."""
    p = Vector(p)
    cands = [Vector((0.0, 0.0, min(max(p.z, c.heel_c.z), c.h - 0.3)))]
    if c.FOOT:
        a, b = c.foot_axis[0], c.toe_c
        ab = b - a
        t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-6)))
        cands.append(a + ab * t)
        cands.append(c.heel_c.copy())
    return min(cands, key=lambda q: (q - p).length)


def _project(c, p, lift=0.0):
    """(point, normal) on the body surface under p (cast from inside the body through p)."""
    o = _skeleton_origin(c, p)
    dv = Vector(p) - o
    if dv.length < 1e-5:
        dv = Vector((0.0, -1.0, 0.0))
    hit = c.ray(o, dv)
    if hit is None:
        return Vector(p), dv.normalized()
    q, n = hit
    return q + n * lift, n


def _leg_quad(c, q00, q10, q11, q01, nu, nv, lift, pal, name="decal"):
    """A printed decal on the leg over the (angle, z) quad q00-q10-q11-q01 (bilinear, nu x nv
    cells): a single surface `lift` off the leg, shaded like the leg itself. No outline."""
    def at(u, v):
        a = _lerp(_lerp(q00[0], q10[0], u), _lerp(q01[0], q11[0], u), v)
        z = _lerp(_lerp(q00[1], q10[1], u), _lerp(q01[1], q11[1], u), v)
        return a, z
    rows = [[c.surface(*at(j / nu, i / nv), lift)[0] for j in range(nu + 1)] for i in range(nv + 1)]
    return _grid_shell(rows, _axis_inside, pal=pal, name=name)


def _pad(to3d, inside, bnd, ctr, lift, ts=(0.3, 0.6, 0.85, 1.0), skirt=0.04, pal=0, name="pad",
         outline=True, smooth=True, jag_from=None):
    """A raised pad on the body: rings from an interior point ctr (u, v) out to the closed boundary
    bnd [(u, v)], mapped by to3d(u, v, lift) -> Vector; lift(t, u, v) is the height off the surface
    (t = 0 centre .. 1 boundary); a skirt from the boundary `skirt` into the body hides the seam.
    pal: an int or fn(t, u, v) -> colour of each face (t, u, v at the face's middle).
    jag_from: the rings inside t < jag_from follow a smoothed boundary and the jags fade in only
    beyond it, so a jagged outline doesn't run valleys (and outline-hull creases) to the middle."""
    bm = bmesh.new()
    pals = []
    smooth_b = list(bnd)
    if jag_from is not None:
        for _it in range(6):
            n_ = len(smooth_b)
            smooth_b = [((smooth_b[k - 1][0] + 2 * smooth_b[k][0] + smooth_b[(k + 1) % n_][0]) / 4,
                         (smooth_b[k - 1][1] + 2 * smooth_b[k][1] + smooth_b[(k + 1) % n_][1]) / 4) for k in range(n_)]
    c0 = bm.verts.new(to3d(ctr[0], ctr[1], lift(0.0, ctr[0], ctr[1])))
    rings, params = [], []
    for t in ts:
        ring, prm = [], []
        w = 1.0 if jag_from is None else _smooth((t - jag_from) / max(1.0 - jag_from, 1e-3))
        for (bu, bv), (su, sv) in zip(bnd, smooth_b):
            bu, bv = _lerp(su, bu, w), _lerp(sv, bv, w)
            u, v = _lerp(ctr[0], bu, t), _lerp(ctr[1], bv, t)
            ring.append(bm.verts.new(to3d(u, v, lift(t, u, v))))
            prm.append((t, u, v))
        rings.append(ring)
        params.append(prm)
    sk = [bm.verts.new(to3d(bu, bv, -skirt)) for bu, bv in bnd]
    n = len(bnd)

    def colour(t, u, v):
        return pal(t, u, v) if callable(pal) else pal

    for k in range(n):
        k2 = (k + 1) % n
        bm.faces.new((c0, rings[0][k], rings[0][k2]))
        t, u, v = params[0][k]
        pals.append(colour(t * 0.5, _lerp(ctr[0], u, 0.5), _lerp(ctr[1], v, 0.5)))
    for r in range(len(rings) - 1):
        for k in range(n):
            k2 = (k + 1) % n
            bm.faces.new((rings[r][k], rings[r + 1][k], rings[r + 1][k2], rings[r][k2]))
            (ta, ua, va), (tb, ub, vb) = params[r][k], params[r + 1][k2]
            pals.append(colour((ta + tb) / 2, (ua + ub) / 2, (va + vb) / 2))
    for k in range(n):
        k2 = (k + 1) % n
        bm.faces.new((rings[-1][k], sk[k], sk[k2], rings[-1][k2]))
        t, u, v = params[-1][k]
        pals.append(colour(1.0, u, v))
    _orient(bm, inside)
    return _piece(bm, pals, outline, smooth, name)


def _inked_plate(fp, shape, pal, border=0.03, lift=0.026, n=11, name="plate"):
    """A colour plate with an even ink border on a surface given by fp(x, z, lift) -> (p, n);
    shape(g) -> (x0, x1, top(u), bot(u)) is the outline grown by g."""
    out = []
    for g, lf, pl, nm, k in ((border, lift - 0.012, K.BLACK, name + "_ink", n + 2), (0.0, lift, pal, name, n)):
        x0, x1, top, bot = shape(g)
        us = [_lerp(x0, x1, i / (k - 1)) for i in range(k)]
        bm = bmesh.new()
        cols = []
        for u in us:
            zt, zb = top(u), bot(u)
            if zt - zb < 0.004:
                zt, zb = zt + 0.002, zb - 0.002
            col = []
            for z in (zt, zb):
                p, nn = fp(u, z, 0.0)
                col.append((bm.verts.new(p + nn * lf), bm.verts.new(p + nn * (lf - 0.03))))
            cols.append(col)
        for a, b in zip(cols, cols[1:]):
            (at, atb), (ab, abb) = a
            (bt, btb), (bb, bbb) = b
            bm.faces.new((at, ab, bb, bt))
            bm.faces.new((atb, btb, bbb, abb))
            bm.faces.new((at, bt, btb, atb))
            bm.faces.new((ab, abb, bbb, bb))
        for col, flip in ((cols[0], False), (cols[-1], True)):
            (t, tb), (b, bb_) = col
            bm.faces.new((t, tb, bb_, b) if not flip else (t, b, bb_, tb))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        out.append(_piece(bm, pl, False, True, nm))
    return out


def _splat(rng, n, rx, ry, drip=0.55):
    """An irregular stain outline (n points) around (0, 0): a lumpy blob with a drip running down
    (a dried spill, not a round cookie)."""
    a3, a5 = rng.uniform(0, 6.3), rng.uniform(0, 6.3)
    out = []
    for k in range(n):
        ph = 2 * math.pi * k / n
        f = 1.0 + 0.2 * math.sin(3 * ph + a3) + 0.1 * math.sin(5 * ph + a5) + rng.uniform(-0.05, 0.05)
        dd = _wrap(ph + math.pi / 2)               # 0 = straight down
        f *= 1.0 + drip * math.exp(-(dd / 0.22) ** 2)
        out.append((math.cos(ph) * rx * f, math.sin(ph) * ry * f))
    return out


# ------------------------------------------------------------------ pads of any outline (beards, ink borders)
def _poly_inside(pt, poly):
    """Even-odd test: is the 2D point inside the closed polygon [(u, v)]?"""
    x, y = pt
    ins = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x1 + (y - y1) * (x2 - x1) / (y2 - y1) > x:
            ins = not ins
    return ins


def _poly_dist(pt, poly):
    """Distance from a 2D point to the closed polygon's outline."""
    px, py = pt
    best = 1e9
    n = len(poly)
    for i in range(n):
        ax, ay = poly[i]
        bx, by = poly[(i + 1) % n]
        dx, dy = bx - ax, by - ay
        l2 = dx * dx + dy * dy
        t = 0.0 if l2 < 1e-12 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
        best = min(best, math.hypot(px - ax - dx * t, py - ay - dy * t))
    return best


def _densify(poly, step):
    """The closed polygon with extra points so no edge is longer than `step`."""
    out = []
    n = len(poly)
    for i in range(n):
        (ax, ay), (bx, by) = poly[i], poly[(i + 1) % n]
        k = max(1, int(math.ceil(math.hypot(bx - ax, by - ay) / step)))
        out += [(_lerp(ax, bx, j / k), _lerp(ay, by, j / k)) for j in range(k)]
    return out


def _offset_poly(poly, dist):
    """The closed polygon moved `dist` outward (negative: inward) along its vertex bisectors
    (works for either winding; miters capped at 2.5x)."""
    n = len(poly)
    area = sum(poly[i][0] * poly[(i + 1) % n][1] - poly[(i + 1) % n][0] * poly[i][1] for i in range(n))
    sgn = 1.0 if area > 0 else -1.0                # counter-clockwise: outward normal = (dy, -dx)
    out = []
    for i in range(n):
        (px, py), (cx, cy), (nx, ny) = poly[i - 1], poly[i], poly[(i + 1) % n]
        e1 = Vector((cx - px, cy - py))
        e2 = Vector((nx - cx, ny - cy))
        e1 = e1.normalized() if e1.length > 1e-9 else e2.normalized()
        e2 = e2.normalized() if e2.length > 1e-9 else e1
        n1 = Vector((e1.y, -e1.x)) * sgn
        n2 = Vector((e2.y, -e2.x)) * sgn
        bis = n1 + n2
        bis = bis.normalized() if bis.length > 1e-6 else n1
        k = 1.0 / max(bis.dot(n1), 0.4)
        out.append((cx + bis.x * dist * k, cy + bis.y * dist * k))
    return out


def _pillow(to3d, inside, bnd, height, pal, spacing=0.09, skirt=0.05, outline=True, name="pillow"):
    """A raised pad of ANY outline (deep notches, spikes, tufts): the closed polygon bnd [(u, v)]
    is filled by a constrained Delaunay triangulation with interior points ~`spacing` apart, and
    each point is lifted height(dist, u, v) off the body, dist = its distance to the outline (so the
    pad is a soft pillow whose edge stands height(0, ..) proud and the outline hull shows all round);
    a skirt from the outline `skirt` into the body hides the seam. to3d(u, v, lift) -> Vector maps
    it onto the body; pal: an int or fn(dist, u, v) -> colour."""
    bnd = _densify(bnd, spacing * 0.6)
    nb = len(bnd)
    us, vs = [p[0] for p in bnd], [p[1] for p in bnd]
    pts = list(bnd)
    v, row = min(vs) + spacing * 0.43, 0
    while v < max(vs):
        u = min(us) + (spacing * 0.5 if row % 2 else 0.0)
        while u < max(us):
            if _poly_inside((u, v), bnd) and _poly_dist((u, v), bnd) > spacing * 0.45:
                pts.append((u, v))
            u += spacing
        v += spacing * 0.866
        row += 1
    vco, _e, faces, orig, _oe, _of = delaunay_2d_cdt([Vector(p) for p in pts], [], [list(range(nb))], 1, 1e-7)
    new_of = {}
    for k, origs in enumerate(orig):
        for o in origs:
            new_of[o] = k
    on_b = {new_of[i] for i in range(nb) if i in new_of}
    dist = [0.0 if k in on_b else _poly_dist((q.x, q.y), bnd) for k, q in enumerate(vco)]
    bm = bmesh.new()
    hts = [height(dist[k], q.x, q.y) for k, q in enumerate(vco)]
    nbr = [set() for _q in vco]
    for f in faces:
        for i in f:
            nbr[i].update(f)
    for _it in range(3):                           # soften the creases along the outline's medial axis
        hts = [hts[k] if k in on_b else 0.5 * hts[k] + 0.5 * sum(hts[j] for j in nbr[k]) / len(nbr[k])
               for k in range(len(vco))]
    V = [bm.verts.new(to3d(q.x, q.y, hts[k])) for k, q in enumerate(vco)]
    pals = []

    def colour(dd, u, v):
        return pal(dd, u, v) if callable(pal) else pal
    for f in faces:
        if len(set(f)) < 3:
            continue
        try:
            bm.faces.new([V[i] for i in f])
        except ValueError:
            continue
        pals.append(colour(sum(dist[i] for i in f) / len(f), sum(vco[i].x for i in f) / len(f),
                           sum(vco[i].y for i in f) / len(f)))
    S = [bm.verts.new(to3d(u, v, -skirt)) for u, v in bnd]
    for k in range(nb):
        k2 = (k + 1) % nb
        a, b = new_of.get(k), new_of.get(k2)
        if a is None or b is None or a == b:
            continue
        try:
            bm.faces.new((V[a], S[k], S[k2], V[b]))
        except ValueError:
            continue
        pals.append(colour(0.0, bnd[k][0], bnd[k][1]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _orient(bm, inside)
    return _piece(bm, pals, outline, True, name)


def _outline_ring(to3d, poly, inner, outer, lift, pal=None, name="inkring"):
    """A flat band between the polygon moved `inner` (negative = inward) and `outer` outward, lifted
    `lift` off the body: the bold ink border under a raised pad (a pad's own outline hull hardly
    shows where its edge meets the body it lies on)."""
    pal = K.BLACK if pal is None else pal
    a, b = _offset_poly(poly, inner), _offset_poly(poly, outer)
    bm = bmesh.new()
    A = [bm.verts.new(to3d(u, v, lift)) for u, v in a]
    B = [bm.verts.new(to3d(u, v, lift)) for u, v in b]
    n = len(poly)
    for k in range(n):
        k2 = (k + 1) % n
        try:
            bm.faces.new((A[k], B[k], B[k2], A[k2]))
        except ValueError:
            pass
    bm.normal_update()
    for f in bm.faces:
        cen = f.calc_center_median()
        if f.normal.dot(cen - Vector((0.0, 0.0, cen.z))) < 0:
            f.normal_flip()
    return _piece(bm, pal, False, True, name)


def _leg_pal(c, z):
    """The leg's own colour at height z: the cuff band above cuff_z, a stripe's colour inside a
    stripe, else the body (for pieces that must blend into the leg, like eyelids)."""
    if z > c.cuff_z:
        return c.cuff
    scale = c.h / 4.2 if not c.spec.get("tall") else 1.0
    for z0, z1, col in c.spec.get("stripes", []):
        if z0 * scale <= z <= z1 * scale:
            return c.accent if col == "accent" else color(col)
    return c.body


# ------------------------------------------------------------------ eyelids
def _eye_cap(pal, axis, ang, T, lift=0.03, seg=16, rings=3, name="lid"):
    """The part of an eyeball within `ang` of the local direction `axis` (unit sphere -> eyeball
    via T), lifted `lift` along the surface: eyelids."""
    axis = Vector(axis).normalized()
    ref = Vector((0, 0, 1)) if abs(axis.z) < 0.9 else Vector((1, 0, 0))
    e1 = axis.cross(ref).normalized()
    e2 = axis.cross(e1).normalized()
    bm = bmesh.new()
    top = bm.verts.new(axis)
    prev = None
    for r in range(1, rings + 1):
        a = ang * r / rings
        ring = [bm.verts.new(axis * math.cos(a) + (e1 * math.cos(2 * math.pi * j / seg) + e2 * math.sin(2 * math.pi * j / seg)) * math.sin(a))
                for j in range(seg)]
        if prev is None:
            for j in range(seg):
                bm.faces.new((top, ring[j], ring[(j + 1) % seg]))
        else:
            for j in range(seg):
                bm.faces.new((prev[j], ring[j], ring[(j + 1) % seg], prev[(j + 1) % seg]))
        prev = ring
    bm.normal_update()
    bm.faces.ensure_lookup_table()
    if bm.faces[0].normal.dot(bm.faces[0].calc_center_median()) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    nmat = T.to_3x3().inverted().transposed()
    for v in bm.verts:
        nn = (nmat @ v.co).normalized()
        v.co = T @ v.co + nn * lift
    return _piece(bm, pal, False, True, name)


def _lids(c, pal, tilt, ang, lift=0.034, line_r=0.044, tail=0.0, name="lid"):
    """Eyelids over both eyes: a cap of colour `pal` over the part of each eyeball within `ang`
    radians of an axis in the eye's plane, `tilt` radians up from the eye's OUTER side (pi/2 =
    straight up), leaning 0.15 toward the viewer; plus a thick ink line along the visible edge of
    the lid, and optionally a `tail` (radians) running on down the outer rim (a droopy corner)."""
    out = []
    for i, (T, wrap) in enumerate(zip(c.eye_mats, c.eye_wrap)):
        ctr, n = Vector(c.eyes[i]), Vector(c.eye_n[i]).normalized()
        xa = Vector((0, 0, 1)).cross(n).normalized()
        ya = n.cross(xa).normalized()
        s = -1.0 if ctr.x < 0 else 1.0               # outer side of this eye (world x)
        ax = Vector((s * math.cos(tilt), math.sin(tilt), 0.15)).normalized()
        lid = _eye_cap(pal, ax, ang, T, lift=lift, seg=16, rings=3, name=name)
        for v in lid.mesh.vertices:
            v.co = wrap(v.co)
        lid.mesh.update()
        Tn = T.to_3x3().inverted().transposed()
        e1 = Vector((0.0, 0.0, 1.0))
        e1 = (e1 - ax * e1.dot(ax)).normalized()     # toward the viewer
        e2 = ax.cross(e1).normalized()
        run = []                                     # the border circle's front half, in order
        for k in range(13):
            ph = -math.pi / 2 + math.pi * k / 12
            q = ax * math.cos(ang) + (e1 * math.cos(ph) + e2 * math.sin(ph)) * math.sin(ang)
            if q.z > 0.02:
                run.append(q)
        pts = [wrap(T @ q + (Tn @ q).normalized() * (lift + 0.012)) for q in run]
        nrms = [(Tn @ q).normalized() for q in run]
        if tail and run:
            # continue from the outer end down round the rim
            outer_first = run[0].x * s > run[-1].x * s
            qo = run[0] if outer_first else run[-1]
            psi0 = math.atan2(qo.y, qo.x)
            rho = c.eye_rim_r - 0.03
            ext, en = [], []
            for k in range(1, 4):
                psi = psi0 - s * tail * k / 3
                p = ctr + (xa * math.cos(psi) + ya * math.sin(psi)) * rho + n * 0.05
                ext.append(wrap(p))
                en.append(n)
            if outer_first:
                pts, nrms = list(reversed(ext)) + pts, list(reversed(en)) + nrms
            else:
                pts, nrms = pts + ext, nrms + en
        out += [lid, _ink(pts, nrms, line_r, samples=2, taper=0.5, name=name + "line")]
    return out


def _sad_lids(c, line_r=0.036, lift=0.026):
    """The sheet's Tubolino eyes: the top-outer part of each eye is cut off by a lid in the leg's
    own colour (white, or blue where a stripe runs behind the eye) that covers the white and the
    face of its ink rim there, ending exactly at the rim's outer radius (its skirt runs down into
    the eye under the rim, so the rim's own ink stays outermost and no leg-coloured shell bulges
    past it); it hugs the eye (`lift` over the white so it clears the pupil and glint, 0.006 over
    the rim). A thick ink line along the lid's edge is the eye's upper outline: it rises a little
    past the rim at the inner end (a worried brow) and flicks out past the rim on the outer side
    as a short, slightly drooping tail."""
    out = []
    R, r = c.eye_rim_r, c.eye_r
    a = r * c.eye_flat
    r0 = r - 0.028
    z0 = a * math.sqrt(max(1.0 - r0 * r0 / (r * r), 0.0))
    # the ink rim's bead profile (socks._eye_rim) - the lid must clear it
    prof = [(r0, z0 + 0.003), (_lerp(r0, R, 0.32), z0 + 0.012), (_lerp(r0, R, 0.72), z0 * 0.62), (R, 0.0)]
    Rb = R                                         # the lid ends exactly at the rim's outer edge

    def lid_lift(rho):                             # over the white, then down to hug the rim
        return _lerp(lift, 0.006, _smooth((rho - r * 0.8) / (r * 0.25)))

    def height(rho):
        hh = a * math.sqrt(max(1.0 - (rho / r) ** 2, 0.0)) if rho < r else 0.0
        for (ra, za), (rb, zb) in zip(prof, prof[1:]):
            if ra <= rho <= rb:
                hh = max(hh, _lerp(za, zb, (rho - ra) / (rb - ra)))
        return hh

    # the lid edge in the eye's plane: (u toward the eye's OUTER side, v up) in units of R
    ctrl = [(-0.6, 1.1), (-0.27, 0.87), (0.0, 0.72), (0.42, 0.53), (0.72, 0.33), (0.86, 0.22),
            (1.0 + 0.1 / R, 0.06)]
    curve = [(p.x, p.y) for p in _catmull([(x * R, y * R, 0.0) for x, y in ctrl], 6)]

    def u_at(v):                                   # the edge's u at height v (monotonic in v)
        for (ua, va), (ub, vb) in zip(curve, curve[1:]):
            if min(va, vb) <= v <= max(va, vb) and abs(vb - va) > 1e-9:
                return _lerp(ua, ub, (v - va) / (vb - va))
        return curve[0][0] if v > curve[0][1] else curve[-1][0]
    # where the edge leaves the lid disc on the outer side
    v_exit = curve[-1][1]
    for (ua, va), (ub, vb) in zip(curve, curve[1:]):
        da, db = math.hypot(ua, va) - Rb, math.hypot(ub, vb) - Rb
        if ua > 0 and da <= 0 < db:
            v_exit = _lerp(va, vb, -da / (db - da))
            break
    stripes = [(z0_ * c.h / 4.2 - c.ey, z1_ * c.h / 4.2 - c.ey) for z0_, z1_, _cc in c.spec.get("stripes", [])]
    for i, (T, wrap) in enumerate(zip(c.eye_mats, c.eye_wrap)):
        ctr, n = Vector(c.eyes[i]), Vector(c.eye_n[i]).normalized()
        xa = Vector((0, 0, 1)).cross(n).normalized()
        ya = n.cross(xa).normalized()
        s = -1.0 if ctr.x < 0 else 1.0             # world x sign of this eye's outer side

        def at(u, v, hh):
            return wrap(ctr + xa * (s * u) + ya * v + n * hh)
        # rows of constant v (= constant z: the eye plane is vertical), cut at the stripe borders
        vtop = Rb * 0.995
        vrows = [_lerp(v_exit, vtop, k / 9) for k in range(10)]
        vrows = sorted(set(vrows + [b for st in stripes for b in st if v_exit < b < vtop]))
        bm = bmesh.new()
        rows, pals = [], []
        ncol = 8
        for v in vrows:
            ch = math.sqrt(max(Rb * Rb - v * v, 0.0))
            u0, u1 = max(-ch, u_at(v)), ch
            u0 = min(u0, u1)
            rows.append([bm.verts.new(at(_lerp(u0, u1, k / ncol), v,
                                         height(math.hypot(_lerp(u0, u1, k / ncol), v))
                                         + lid_lift(math.hypot(_lerp(u0, u1, k / ncol), v))))
                         for k in range(ncol + 1)])
        for ra, rb, va, vb in zip(rows, rows[1:], vrows, vrows[1:]):
            for k in range(ncol):
                bm.faces.new((ra[k], ra[k + 1], rb[k + 1], rb[k]))
                pals.append(_leg_pal(c, c.ey + (va + vb) / 2))
        # a short skirt from the lid's outer arc down into the eye, under the rim's bead
        th0 = math.atan2(v_exit, math.sqrt(max(Rb * Rb - v_exit * v_exit, 0.0)))
        th1 = math.atan2(vrows[-1], -math.sqrt(max(Rb * Rb - vrows[-1] ** 2, 0.0)))
        top, base = [], []
        for k in range(13):
            th = _lerp(th0, th1, k / 12)
            dv = xa * (s * math.cos(th)) + ya * math.sin(th)
            top.append(bm.verts.new(wrap(ctr + dv * Rb + n * (height(Rb) + lid_lift(Rb)))))
            base.append(bm.verts.new(wrap(ctr + dv * (Rb - 0.05) - n * 0.03)))
        for k in range(12):
            bm.faces.new((top[k], top[k + 1], base[k + 1], base[k]))
            pals.append(_leg_pal(c, (top[k].co.z + base[k + 1].co.z) / 2))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        _orient(bm, lambda q, ctr=ctr, n=n: ctr - n * 0.3)
        out.append(_piece(bm, pals, False, True, "lid"))
        # the thick ink line along the lid edge, past the rim at both ends
        pts, nrms = [], []
        for u, v in curve:
            rho = math.hypot(u, v)
            if rho <= Rb:
                pts.append(at(u, v, height(rho) + lid_lift(rho) + 0.014))
                nrms.append(n)
            else:
                p2 = ctr + xa * (s * u) + ya * v
                ho = Vector((p2.x, p2.y, 0.0)).normalized()
                hit = c.ray(p2 + ho * 1.5, -ho)
                q, nn = hit if hit else (p2, n)
                pts.append(q + nn * 0.014)
                nrms.append(nn)
        out.append(_ink(pts[::2] + ([pts[-1]] if len(pts) % 2 == 0 else []),
                        nrms[::2] + ([nrms[-1]] if len(nrms) % 2 == 0 else []),
                        line_r, samples=3, taper=0.35, name="lidline"))
    return out


# ------------------------------------------------------------------ Tubolino
def feat_tubolino(c):
    """Sheet: sad eyes - a lid cuts off the top-outer part of each eye, its thick ink edge rising
    into a worried brow at the inner end and flicking out past the eye at the outer end - and a
    frown."""
    out = _sad_lids(c)
    w, my = 0.22, c.mouth_z
    xs = [-w, -w * 0.5, 0.0, w * 0.5, w]
    hits = [c.face_point(x, my + (-0.11 * (x / w) ** 2 + 0.14), 0.012) for x in xs]
    out.append(_ink([p for p, _n in hits], [n for _p, n in hits], INK, taper=0.7, name="frown"))
    return out


# ------------------------------------------------------------------ AnkleBiter
def feat_anklebiter(c, raise_by=0.06):
    """Sheet: the shared short body + the shared 'fangs' grin, redrawn here `raise_by` higher
    (SPEC_OVERRIDES turns the shared mouth off): on the sheet the grin sits closer under the eyes
    than socks.face_pieces puts a mouth. Same drawing as the shared one: a wide grin line under
    both eyes, a dark crescent mouth and two broad white fangs hanging from it."""
    import socks as SK                             # lazily: socks imports this module
    fp = c.face_point
    dd = c.d if c.d else 1.0
    my = c.mouth_z + raise_by
    w = 0.5

    def grin(x):
        return my + 0.1 * ((x / w) ** 2) - 0.04
    xs = [-w, -w * 0.5, 0.0, w * 0.5, w]
    hits = [fp(x, grin(x), 0.012) for x in xs]
    out = [SK._ink([p for p, _n in hits], [n for _p, n in hits], SK.INK, name="mouth")]
    mo = 0.4
    out.append(SK._plate(fp, [_lerp(-mo, mo, i / 10) for i in range(11)], grin,
                         lambda u: grin(u) - 0.12 * math.sqrt(max(1 - (u / mo) ** 2, 0.0)),
                         0.006, c.body_deep, name="mouthin"))
    for fx in (-0.3 * dd, 0.26 * dd):
        z0 = grin(fx) - SK.INK * 0.7

        def fang(g, fx=fx, z0=z0):
            fw, fl = 0.1 + g, 0.29 + 1.7 * g
            return (fx - fw, fx + fw, (lambda u: z0 + g * 0.6),
                    (lambda u: z0 - fl * (1 - min(abs(u - fx) / fw, 1.0) ** 1.3)))
        out += SK._inked(fp, fang, K.WHITE, border=0.026, lift=0.03, n=9, name="fang")
    return out


# ------------------------------------------------------------------ CrustyCrew
def feat_crusty(c):
    """A stiff, crusty tan sock that dried rigid: two broad, angular crumple folds round the ankle
    and the mid-leg whose ridges stand proud enough to put small angular kinks into the outline
    (a darker fold shade on the underside of each ridge), a stiff dog-ear of the rim folded over
    and out on the heel side, a few big flat dried patches (one by the toe-side eye, one on the
    instep, one on the back) with broken ink borders and a couple of crumbs, and half-lidded,
    unimpressed eyes over the flat mouth."""
    tid, d = c.tid, (c.d or 1.0)
    crust = hexcol(f"{tid}_crust", "#9A8454")      # ~15% darker than the heel/toe colour
    crumb = hexcol(f"{tid}_crumb", "#E6D29E")
    fold = hexcol(f"{tid}_fold", "#BCA169")
    rng = random.Random(11)
    out = []
    hs = c.h / 4.2
    leg = _leg_map(c)
    out += _crumple(c, d, fold)
    out += _rim_flap(c, d)
    # big flat dried patches: (angle, z, rx, ry, crumbs), mirrored by d
    spots = [(0.98, c.ey - 0.3 * hs, 0.22, 0.25, 0),          # beside the toe-side eye
             (2.75, c.mouth_z - 0.05 * hs, 0.42, 0.36, 1)]     # on the back
    for ang, z, rx, ry, ncrumb in spots:
        a = d * ang
        r = c.radius_at(z, a)
        s0 = a * r
        bnd = [(s0 + d * u, z + v) for u, v in _splat(rng, 18, rx, ry, drip=0.35)]
        out += _crust_stain(leg, _axis_inside, bnd, (s0, z), crust)
        for k in range(ncrumb):
            out.append(_crumb(c, c.surface(a + d * rng.uniform(-0.25, 0.25) * rx / r, z + rng.uniform(-0.2, 0.25) * ry,
                                           0.03), crumb, rng))
    if c.FOOT:                                     # a big patch on the instep / foot top, toe side
        base = Vector((d * c.FOOT * 0.55, -0.32, c.instep_z - 0.3 * hs))
        p0, n0 = _project(c, base)
        t1, t2 = _frame(n0)
        bnd = _splat(rng, 18, 0.36, 0.3, drip=0.0)

        def to3d(u, v, lf):
            return _project(c, p0 + t1 * (u * d) + t2 * v + n0 * 0.2, lf)[0]
        out += _crust_stain(to3d, lambda q: _skeleton_origin(c, q), bnd, (0.0, 0.0), crust)
        for k in range(2):
            q = p0 + t1 * (d * rng.uniform(-0.15, 0.15)) + t2 * rng.uniform(-0.1, 0.12)
            out.append(_crumb(c, _project(c, q + n0 * 0.2, 0.03), crumb, rng))
    # half-lidded, unimpressed eyes (the lid edge straight across, just above the pupils)
    out += _lids(c, c.body, math.radians(90), math.radians(62), line_r=0.04)
    return out


def _crumb(c, hit, pal, rng):
    """A small flat crumb lying on the surface (p, n)."""
    p, n = hit
    t1, t2 = _frame(n)
    sc = rng.uniform(0.05, 0.065)
    mat = Matrix.Translation(p) @ Matrix((t1, t2, n)).transposed().to_4x4() @ \
        Matrix.Rotation(rng.uniform(0, 3), 4, "Z") @ Matrix.Diagonal(Vector((sc * 1.3, sc, sc * 0.45, 1)))
    return K.sphere(pal, 1.0, mat, seg=6, rings=4, outline=False, smooth=True, name="crumb")


def _crust_stain(to3d, inside, bnd, ctr, pal, name="crust"):
    """A big flat dried patch (lifted 0.022, a tiny dome) on a BROKEN ink border: the black plate
    under it (0.012 lower) is grown by a varying amount and dips under the patch in a couple of
    places, so the outline reads hand-drawn, not like a sticker."""
    n = len(bnd)
    rng = random.Random(len(bnd) * 7 + int(abs(ctr[0]) * 100))
    ph1, ph2 = rng.uniform(0, 6.3), rng.uniform(0, 6.3)
    grown = []
    for k, (u, v) in enumerate(bnd):
        a = 2 * math.pi * k / n
        w = 0.03 + 0.014 * math.sin(3 * a + ph1) + 0.008 * math.sin(7 * a + ph2)
        if math.sin(2 * a + ph2) > 0.8:            # a gap in the ink
            w = -0.02
        dv = Vector((u - ctr[0], v - ctr[1]))
        dv = dv.normalized() * (dv.length + w) if dv.length > 1e-6 else dv
        grown.append((ctr[0] + dv.x, ctr[1] + dv.y))

    def lift(t, u, v):
        return 0.022 + 0.006 * (1 - t * t)
    return [_pad(to3d, inside, grown, ctr, lambda t, u, v: lift(t, u, v) - 0.012, ts=(0.5, 1.0), skirt=0.04,
                 pal=K.BLACK, name=name + "_ink", outline=False),
            _pad(to3d, inside, bnd, ctr, lift, ts=(0.5, 1.0), skirt=0.03, pal=pal, name=name, outline=False)]


def _crumple(c, d, fold):
    """Crumple folds of a sock that dried stiff: two broad, angular ridges round the ankle and the
    mid-leg. Each zig-zags up and down in straight runs between sharp kinks, its gentle upper side
    rises out of the leg in the body colour to a ridge standing up to ~0.1 proud (most at the
    sides, so the outline kinks there from the front, 3/4 and back), and its steep underside is a
    darker fold shade. One closed shell each, inked by its own outline hull."""
    out = []
    hs = c.h / 4.2
    # (centre z, [(angle deg (mirrored by d), z offset, prominence)] kink vertices round the leg)
    folds = [(c.instep_z + 0.14 * hs, [(0, 0.03, 0.05), (40, -0.06, 0.07), (85, 0.07, 0.1), (130, -0.03, 0.08),
                                       (175, 0.06, 0.09), (220, -0.05, 0.08), (268, 0.06, 0.1), (315, -0.04, 0.07)]),
             (c.mouth_z - 0.43 * hs, [(20, -0.04, 0.05), (62, 0.05, 0.08), (100, -0.06, 0.1), (150, 0.04, 0.08),
                                      (200, -0.05, 0.09), (250, 0.05, 0.08), (285, -0.06, 0.1), (330, 0.04, 0.06)])]
    for zc, kinks in folds:
        ks = sorted(kinks)
        angs = sorted(set([k[0] for k in ks] + [x * 7.5 for x in range(48)]))

        def at(adeg, ks=ks):                       # piecewise linear between the kinks
            for (a0, z0, p0), (a1, z1, p1) in zip(ks + [(ks[0][0] + 360, ks[0][1], ks[0][2])],
                                                   ks[1:] + [(ks[0][0] + 360, ks[0][1], ks[0][2])]):
                aa = adeg if adeg >= ks[0][0] else adeg + 360
                if a0 <= aa <= a1:
                    f = (aa - a0) / max(a1 - a0, 1e-6)
                    return _lerp(z0, z1, f), _lerp(p0, p1, f)
            return ks[0][1], ks[0][2]
        hs_ = hs
        prof = [(0.2, -0.015, 0), (0.1, 0.35, 0), (0.015, 1.0, 1), (-0.04, 0.72, 1), (-0.085, -0.015, 1)]
        rows = []
        for dz, lf, _col in prof:
            row = []
            for adeg in angs:
                zo, pr = at(adeg)
                a = d * math.radians(adeg)
                z = zc + zo * hs_ + dz * hs_
                row.append(c.surface(a, z, lf * pr if lf > 0 else lf)[0])
            rows.append(row)
        out.append(_grid_shell(rows, _axis_inside, closed_u=True,
                               pal=lambda i, j: fold if prof[i][2] else c.body, name="crease", outline=True))
    return out


def _rim_flap(c, d):
    """A stiff dog-ear of the rim folded over on the heel side: one continuous fold that comes up
    from inside the opening, rolls over the lip (hugging it - no gap from above, never higher
    than the lip plus its own thickness) and then juts down and out at ~30 degrees, about 0.6 of
    the leg's width wide, its lower edge a lopsided point. Outside: the ribbed cuff colours;
    underneath (the sock's inside, turned out): the darker body colour."""
    hs = c.h / 4.2
    h, R, ro, t = c.h, c.top_r, c.open_r, c.lip_t
    ac = -d * math.radians(108)                    # centre: on the heel side, toward the back
    half = 0.6 * R / R * 1.0                       # 0.6 of the leg width as an arc -> +-0.6 rad
    nu = 12
    Lmax = 0.62 * hs
    th = 0.022                                     # half thickness of the cloth

    def length(u):                                 # a lopsided dog-ear: longest at u = 0.62
        tent = 1.0 - abs(u - 0.62) / (0.62 if u < 0.62 else 0.38)
        return Lmax * (0.3 + 0.7 * max(tent, 0.0) ** 0.9)
    tilt = math.radians(30.0)
    cols_out, cols_in = [], []
    for j in range(nu + 1):
        u = j / nu
        a = ac + d * (u - 0.5) * 2 * half
        rad = Vector((math.sin(a), -math.cos(a), 0.0))
        L = length(u)
        # the cloth's mid line in (radius, z): inside the hole -> over the lip -> down and out
        mid = [(ro - 0.035, h - 0.13), (ro - 0.035, h - 0.04), (ro + t * 0.15, h + th + 0.012),
               (R - 0.03, h + th + 0.008), (R + th + 0.01, h - 0.05)]
        p_end = Vector((R + th + 0.01, h - 0.05))
        dirv = Vector((math.sin(tilt), -math.cos(tilt)))
        for k in range(1, 4):
            q = p_end + dirv * (L * k / 3)
            mid.append((q.x, q.y))
        line = [Vector(m) for m in mid]
        po, pi = [], []
        for i, m in enumerate(line):
            tg = (line[min(i + 1, len(line) - 1)] - line[max(i - 1, 0)]).normalized()
            nrm = Vector((tg.y, -tg.x))            # points outward/up (away from the sock)
            if nrm.x + nrm.y < 0:
                nrm = -nrm
            o, ii = m + nrm * th, m - nrm * th
            po.append(rad * o.x + Vector((0.0, 0.0, o.y)))
            pi.append(rad * ii.x + Vector((0.0, 0.0, ii.y)))
        cols_out.append(po)
        cols_in.append(pi)
    bm = bmesh.new()
    O = [[bm.verts.new(p) for p in col] for col in cols_out]
    I = [[bm.verts.new(p) for p in col] for col in cols_in]
    m = len(cols_out[0])
    pals = []
    rib = c.cuff_rib if c.ribs else c.cuff
    for j in range(nu):
        for i in range(m - 1):
            bm.faces.new((O[j][i], O[j][i + 1], O[j + 1][i + 1], O[j + 1][i]))
            pals.append(rib if (c.ribs and j % 2) else c.cuff)
            bm.faces.new((I[j][i], I[j + 1][i], I[j + 1][i + 1], I[j][i + 1]))
            pals.append(c.body_dark)
    for j, flip in ((0, False), (nu, True)):       # side edges
        for i in range(m - 1):
            f = (O[j][i], I[j][i], I[j][i + 1], O[j][i + 1])
            bm.faces.new(f if not flip else tuple(reversed(f)))
            pals.append(c.body_dark)
    for i, flip in ((m - 1, False), (0, True)):    # the lower edge and the root inside the hole
        for j in range(nu):
            f = (O[j][i], O[j + 1][i], I[j + 1][i], I[j][i])
            bm.faces.new(f if not flip else tuple(reversed(f)))
            pals.append(c.body_dark)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return [_piece(bm, pals, True, True, "flap")]


# ------------------------------------------------------------------ GymGary
def feat_gymgary(c):
    """A chunky red terry sweatband with a white stripe round the top of the leg, and big sweat
    drops on the face and sides."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    red = c.accent
    white = hexcol(f"{tid}_bandw", "#FFF4EE")
    drop = hexcol(f"{tid}_sweat", "#8FD3FF")
    drop2 = hexcol(f"{tid}_sweat2", "#EAF8FF")
    out = []
    z0, z1 = c.cuff_z - 0.1 * h / 4.2, h - 0.05
    th = 0.11                                     # a terry band hugging the leg
    zs = [_lerp(z0 + 0.07, z1 - 0.07, k / 8) for k in range(9)]
    prof = [(z0 + 0.02, -0.03), (z0, th * 0.45), (z0 + 0.03, th * 0.85)] + [(z, th) for z in zs] + \
           [(z1 - 0.03, th * 0.85), (z1, th * 0.45), (z1 - 0.02, -0.03)]
    nseg = 32
    rows = [[c.surface(2 * math.pi * j / nseg, zz, lf)[0] for j in range(nseg)] for zz, lf in prof]
    zmid, half = (z0 + z1) / 2, (z1 - z0) * 0.13

    def pal(i, j):
        zz = (prof[i][0] + prof[i + 1][0]) / 2
        return white if abs(zz - zmid) < half and 2 < i < len(prof) - 4 else red
    out.append(_grid_shell(rows, _axis_inside, closed_u=True, pal=pal, name="sweatband", outline=True))
    # sweat drops: teardrops sliding down, tips up, all clear of the eyes from the front and 3/4:
    # a big one on the forehead between the band and the heel-side brow (its tip tucked under the
    # band), a smaller one running down the toe-side cheek below and outside the eye, one on the back
    z_fore = _lerp(c.ey + c.eye_rim_r, z0, 0.55)
    for ang, z, r in ((-d * 0.5, z_fore, 0.12), (d * 0.9, c.mouth_z - 0.02, 0.12), (d * 2.5, c.ey - 0.05, 0.15)):
        out += _drop(c, ang, z, r, drop, drop2)
    return out


def _drop(c, ang, z, r, pal, pal2):
    """A teardrop (round bottom, pointed tip up) standing on the leg surface, with a glint."""
    p, n = c.surface(ang, z, r * 0.55)
    t1, t2 = _frame(n)
    bm = bmesh.new()
    rings = []
    nseg = 12
    prof = [(0.0, -1.0)] + [(math.sin(a), -math.cos(a)) for a in [math.pi * k / 8 for k in range(1, 6)]] + \
           [(0.75, 0.45), (0.45, 1.05), (0.18, 1.55)]
    for rr, zz in prof[1:]:
        rings.append([bm.verts.new(p + (t1 * math.cos(2 * math.pi * j / nseg) * rr + n * math.sin(2 * math.pi * j / nseg) * rr * 0.7 + t2 * zz) * r)
                      for j in range(nseg)])
    bot = bm.verts.new(p + t2 * (-r))
    top = bm.verts.new(p + t2 * (2.0 * r))
    for j in range(nseg):
        j2 = (j + 1) % nseg
        bm.faces.new((bot, rings[0][j2], rings[0][j]))
        bm.faces.new((top, rings[-1][j], rings[-1][j2]))
    for ra, rb in zip(rings, rings[1:]):
        for j in range(nseg):
            j2 = (j + 1) % nseg
            bm.faces.new((ra[j], rb[j], rb[j2], ra[j2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    out = [_piece(bm, pal, True, True, "drop")]
    g = p + n * (r * 0.72) + t1 * (-r * 0.3) + t2 * (r * 0.1)
    out.append(K.sphere(pal2, 1.0, Matrix.Translation(g) @ Matrix((t1, t2, n)).transposed().to_4x4()
                        @ Matrix.Diagonal(Vector((r * 0.2, r * 0.38, r * 0.1, 1))), seg=8, rings=5, outline=False, name="glint"))
    return out


# ------------------------------------------------------------------ Argylo
def feat_argylo(c):
    """Sheet: a band of yellow argyle diamonds (3 rows touching tip to tip, 8 round the leg) with
    thin dark-brown overcheck lines along every other diamond edge, from the cuff down; a gold
    monocle with a light-blue lens over the heel-side eye, a knob, and a gold chain hanging from it
    to a loop on the side of the leg."""
    tid, d = c.tid, (c.d or 1.0)
    yellow = hexcol(f"{tid}_diamond", "#FCC828")
    line = hexcol(f"{tid}_line", "#64401E")
    gold = hexcol(f"{tid}_gold", "#FCC62A")
    lens = hexcol(f"{tid}_lens", "#84C6E4")
    glint = hexcol(f"{tid}_glint", "#D6EEF8")
    out = []
    N, rows = 10, 4
    dth = 2 * math.pi / N                          # one yellow diamond (tip to tip) per dth
    hw = dth / 2
    top = c.cuff_z - 0.01
    # the band reaches down to just above the heel patch (measured on the heel side) and never onto
    # the instep curve: diamond height (tip to tip) about 0.42 (0.3 of the leg width)
    heel_top = c.instep_z
    z = c.instep_z
    while z < c.cuff_z:
        if not c.in_heel(c.surface(-d * math.pi / 2, z)[0]):
            heel_top = z
            break
        z += 0.02
    zr = min(0.45 * c.h / 4.2, (top - max(heel_top, c.instep_z) - 0.06) / rows)
    hh = zr / 2
    for m in range(rows):
        zc = top - hh - m * zr
        for k in range(N):
            a = k * dth                            # a yellow diamond on the front centre
            q = [(a, zc + hh), (a + hw, zc), (a, zc - hh), (a - hw, zc)]
            out.append(_leg_quad(c, q[0], q[1], q[2], q[3], 2, 2, 0.011, yellow, name="diamond"))
    # overcheck lines on every other diamond edge (both diagonals), clipped to the band
    zt, zb = top, top - rows * zr
    slope = hh / hw                                # dz per radian along a diamond edge
    r_mid = c.radius_at((zt + zb) / 2)
    phi = math.atan(slope / r_mid)                 # the lines' angle from horizontal
    da = 0.024 / math.sin(phi) / r_mid             # half the line width, as an angle at fixed z
    z0 = top - hh                                  # centre of the top row's front diamond
    for fam in (1, -1):                            # z + fam * slope * a = const
        for j in range(N // 2):
            const = z0 + hh + 4 * hh * j
            a_t, a_b = (const - zt) / (fam * slope), (const - zb) / (fam * slope)
            out.append(_leg_quad(c, (a_t - da, zt), (a_b - da, zb), (a_b + da, zb), (a_t + da, zt),
                                 14, 1, 0.022, line, name="argline"))
    # monocle over the heel-side eye
    e = 0 if d > 0 else 1
    ctr, n = Vector(c.eyes[e]), Vector(c.eye_n[e]).normalized()
    xa = Vector((0, 0, 1)).cross(n).normalized()
    ya = n.cross(xa).normalized()
    pc = ctr + n * (c.eye_r * c.eye_flat + 0.05)
    R = c.eye_rim_r * 0.98
    rot = Matrix((xa, ya, n)).transposed().to_4x4()
    out.append(K.torus(gold, R, 0.058, Matrix.Translation(pc) @ rot, seg=28, mseg=8, name="monocle"))
    # the sheet inks both edges of the gold ring: a thin black ring just inside it, over the lens
    out.append(K.torus(K.BLACK, R - 0.064, 0.019, Matrix.Translation(pc + n * 0.026) @ rot, seg=28, mseg=6,
                       outline=False, name="monocle_ink"))
    lr, ld = R - 0.01, 0.046
    out.append(K.sphere(lens, 1.0, Matrix.Translation(pc - n * 0.01) @ rot @ Matrix.Diagonal(Vector((lr, lr, ld, 1))),
                        seg=20, rings=8, outline=False, name="lens"))
    # one flat diagonal light streak across the glass (lower-left to upper-right), lying on it
    gd = (xa + ya).normalized()
    gp = (ya - xa).normalized()
    bm = bmesh.new()
    rows = []
    for k in range(7):
        row = []
        for w in (-0.036, 0.036):
            q = gd * _lerp(-0.15, 0.15, k / 6) + gp * (0.045 + w)
            rho = q.length
            hz = ld * math.sqrt(max(1.0 - (rho / lr) ** 2, 0.0)) - 0.01 + 0.007
            row.append(bm.verts.new(pc + q + n * hz))
        rows.append(row)
    for ra, rb in zip(rows, rows[1:]):
        f = bm.faces.new((ra[0], rb[0], rb[1], ra[1]))
        f.normal_update()
        if f.normal.dot(n) < 0:
            f.normal_flip()
    out.append(_piece(bm, glint, False, True, "glint"))
    out_dir = -d * xa                              # the outer (heel) side of that eye
    knob = pc + out_dir * (R + 0.066)              # at 3 o'clock on the ring
    out.append(K.sphere(gold, 0.066, Matrix.Translation(knob), seg=10, rings=6, name="knob"))
    # a thin chain leaves the knob and hangs in one smooth curve, bowing out off the leg toward the
    # heel side, down to the clip loop at the leg's edge (the loop is its lowest point)
    ka = math.atan2(knob.x, -knob.y)
    z_end = c.ey - 0.85 * c.h / 4.2
    a_end = -d * math.radians(82)
    loop_p, loop_n = c.surface(a_end, z_end, 0.07)
    z_in = loop_p.z + 0.1                          # the chain hooks into the top of the loop
    pts = [knob - ya * 0.05]
    for fz, fa, lf in ((0.12, 0.03, 0.1), (0.45, 0.16, 0.15), (0.75, 0.45, 0.16), (0.93, 0.8, 0.12)):
        z = _lerp(knob.z - 0.05, z_in, fz)         # falls steeply from the knob, then swings out
        pts.append(c.surface(_lerp(ka, a_end, fa), z, lf)[0])
    pts.append(loop_p + Vector((0, 0, 0.1)))
    out.append(K.tube(gold, pts, radius=0.03, res=6, bevel_res=1, name="chain"))
    tang = Vector((0, 0, 1)).cross(loop_n).normalized()
    lm = Matrix.Translation(loop_p) @ Matrix((loop_n, tang.cross(loop_n), tang)).transposed().to_4x4()
    out.append(K.torus(gold, 0.09, 0.032, lm @ Matrix.Diagonal(Vector((1.0, 1.2, 1.0, 1))), seg=14, mseg=6, name="loop"))
    return out


# ------------------------------------------------------------------ ToeToe
def _toe_capsule(pal, p0, p1, rw, rh, upv, re=None, seg=12, hr=3, name="toe"):
    """A closed capsule from p0 to p1 with an elliptical cross-section (rw sideways, rh along upv)
    and rounded ends reaching `re` (default rw) past p0 / p1: a fat, slightly tall toe."""
    re = rw if re is None else re
    p0, p1 = Vector(p0), Vector(p1)
    ax = (p1 - p0).normalized()
    e2 = (upv - ax * upv.dot(ax)).normalized()
    e1 = ax.cross(e2).normalized()
    prof = []
    for k in range(1, hr + 1):
        a = math.pi / 2 * (1 - k / hr)
        prof.append((p0 - ax * re * math.sin(a), math.cos(a)))
    for k in range(0, hr):
        a = math.pi / 2 * k / hr
        prof.append((p1 + ax * re * math.sin(a), math.cos(a)))
    bm = bmesh.new()
    rings = [[bm.verts.new(cc + (e1 * (rw * math.cos(2 * math.pi * j / seg)) + e2 * (rh * math.sin(2 * math.pi * j / seg))) * f)
              for j in range(seg)] for cc, f in prof]
    s = bm.verts.new(p0 - ax * re)
    e = bm.verts.new(p1 + ax * re)
    for j in range(seg):
        j2 = (j + 1) % seg
        bm.faces.new((s, rings[0][j2], rings[0][j]))
        bm.faces.new((e, rings[-1][j], rings[-1][j2]))
    for ra, rb in zip(rings, rings[1:]):
        for j in range(seg):
            j2 = (j + 1) % seg
            bm.faces.new((ra[j], rb[j], rb[j2], ra[j2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _piece(bm, pal, True, True, name)


def feat_toetoe(c, big_front=False):
    """A toe sock: the foot ends in five separate fat, rounded toes in the darker toe colour, so the
    toe patch flows straight into them. They lie side by side across the foot's width at nearly
    the same height (the big toe slightly highest and longest, the little toe slightly lowest and
    shortest), start deep inside the toe cap and reach well past the body's own toe tip, fanning
    out a little so deep V gaps let each toe's outline show all round. The whole group is pitched
    up ~17 degrees against the drooping foot ('wiggling'), so the tips rise just above the foot's
    top line and the front and 3/4 silhouettes show a row of five rounded bumps."""
    if not c.FOOT:
        return []
    toe = c.body_dark
    out = []
    fd = c.toe_dir.normalized()
    side = Vector((0.0, 1.0, 0.0)) * (1.0 if big_front else -1.0)
    up = fd.cross(Vector((0.0, 1.0, 0.0))).normalized()
    if up.z < 0:
        up = -up
    pitch = math.radians(17.0)                     # the group points level ('wiggling' up)
    upd = (up * math.cos(pitch) - fd * math.sin(pitch)).normalized()
    tip = c.toe_c + fd * c.toe_radii.x             # the body's own toe tip
    wf = c.toe_radii.y / 0.7                       # foot width scale (1 for the normal foot)
    # (y across from the big toe's side, half width, half height, tip height above the foot axis,
    #  reach of the rounded end past the body's toe tip, fan, extra upward pitch in degrees): big
    # toe first. The tips step back and down toward the little toe and the bigger toes curl up
    # more, so behind the little toe each toe shows only its own rounded tip (five bumps)
    toes = [(-0.62, 0.19, 0.36, 0.2, 0.6, -6.0, 14.0),
            (-0.26, 0.14, 0.31, 0.15, 0.49, -1.0, 9.0),
            (0.03, 0.135, 0.29, 0.1, 0.38, 4.0, 5.0),
            (0.31, 0.13, 0.27, 0.04, 0.27, 9.0, 1.0),
            (0.6, 0.12, 0.25, -0.01, 0.17, 14.0, -3.0)]
    for y, rw, rh, hz, reach, fan, curl in toes:
        ya = side * (y * wf)
        tend = tip + fd * reach + ya               # where the toe's rounded end reaches
        pt = pitch + math.radians(curl)
        dv = (fd * math.cos(pt) + up * math.sin(pt) + side * math.sin(math.radians(fan))).normalized()
        end = tend - dv * rw                       # centre of the end cap
        end += up * (hz - (end - c.toe_c).dot(up)) # tip height above the foot axis
        base = end - dv * (reach + 0.55)          # deep inside the toe cap
        base = base - side * (base - c.toe_c).dot(side) * 0.2    # bases a bit closer together
        under = base - upd * rh                    # keep the toe's underside above the sole there
        hit = c.sole(under.x, under.y)
        if hit is not None and under.z < hit[0].z + 0.06:
            base = base + Vector((0.0, 0.0, hit[0].z + 0.06 - under.z))
        out.append(_toe_capsule(toe, base, end, rw, rh, upd, name="toe"))
        out[-1].rig = dict(head=base, tail=end)    # rigging.py: one bone per toe (Toe1 = big toe)
    return out


# ------------------------------------------------------------------ Sockrates
def feat_sockrates(c):
    """Sheet: a laurel wreath (a big diagonal sprig on the heel side, three leaves poking out on
    the toe side) round the top, a big lobed grey beard under the eyes with a cream two-lobed lip
    under a peaked moustache, and a thin white toga pinned by a round gold brooch on the heel-side
    shoulder, its top edge sweeping diagonally down across the front to the toe side."""
    tid, d = c.tid, (c.d or 1.0)
    grey = hexcol(f"{tid}_beard", "#AEAEAE")
    leaf = hexcol(f"{tid}_leaf", "#58A034")
    leaf2 = hexcol(f"{tid}_leaf2", "#3E7428")
    toga = hexcol(f"{tid}_toga", "#E8F2F9")
    toga2 = hexcol(f"{tid}_toga2", "#D2DEEA")
    fold = hexcol(f"{tid}_fold", "#B0C2D1")
    gold = hexcol(f"{tid}_gold", "#F0BC14")
    gold2 = hexcol(f"{tid}_gold2", "#FCE070")
    out, over = _toga(c, d, toga, toga2, fold, gold, gold2)
    out += _beard(c, grey, over)
    out += _wreath(c, leaf, leaf2, d)
    return out


def _toga(c, d, toga, toga2, fold, gold, gold2):
    """Thin cloth hugging the body, pinned by the brooch on the heel-side shoulder. Its top edge
    peaks exactly at the brooch and falls steeply from it (front and back) to a long, nearly level
    run low round the toe side, so from the front it leaves the brooch and sweeps diagonally down
    under the beard to the toe side. Behind the brooch the front and back panels part in a wedge
    (widest at the top edge, closing lower down) that shows a strip of the leg. Below, one piece
    covers the lower leg, the heel and the instep down to the bare toe, flaring a little at the hem
    over the toe. Long blue-grey fold lines fan out from under the brooch across the front.
    Returns (pieces, over): over(angle, z) is how far the cloth stands off the leg there (with a
    soft ramp just above its top edge), so things drawn on top (the beard) can ride over it."""
    hs = c.h / 4.2
    a_b = -d * math.radians(70)                    # the brooch: the top edge's peak
    z_b = c.ey - 0.84 * hs                         # at mid-beard height
    D0, D1 = 0.45 * hs, 0.45 * hs
    lift0 = 0.024

    def drop(t):                                   # top edge below z_b, t = |angle from the brooch|
        e = 1.0 - (1.0 - min(t / 1.45, 1.0)) ** 2
        return D0 * e + D1 * max(0.0, t - 1.45) / (math.pi - 1.45)

    def z_hi(a):
        return z_b - drop(abs(_wrap(a - a_b)))

    # the parting behind the brooch: a wedge, widest (2 * g_max) at the top edge
    a_g = a_b - d * 0.7
    g_max, g_len = 0.26, 0.85 * hs
    z_top = z_hi(a_g + d * g_max)                  # top of the parting's front edge
    z_end = z_top - g_len

    def gap(z):
        if z <= z_end:
            return 0.0
        return g_max * min(1.0, (z - z_end) / g_len) ** 0.8

    # bottom hem: low over the heel and the sides of the foot, up round the toe patch
    nsamp = 96
    lo = []
    for k in range(nsamp):
        a = 2 * math.pi * k / nsamp
        rest = (0.44 + 0.12 * (1 - math.cos(a)) / 2) * hs
        z = z_hi(a) - 0.3
        while z > rest:
            p, n = c.surface(a, z - 0.03)
            if c.in_toe(p - n * 0.02) or c.in_toe(p + Vector((d * 0.14, 0.0, 0.0))) or n.z < -0.55:
                break
            z -= 0.03
        lo.append(z)
    for _it in range(4):
        lo = [(lo[k - 1] + 2 * lo[k] + lo[(k + 1) % nsamp]) / 4 for k in range(nsamp)]

    def z_lo(a):
        f = (a % (2 * math.pi)) / (2 * math.pi) * nsamp
        k = int(f)
        return _lerp(lo[k % nsamp], lo[(k + 1) % nsamp], f - k)

    def toe_w(a):                                  # 1 on the toe side, 0 from the front / back round
        return max(0.0, math.cos(a - d * math.pi / 2)) ** 1.5

    def lift(a, z):
        f = min(max((z_hi(a) - z) / max(z_hi(a) - z_lo(a), 0.1), 0.0), 1.0)
        flare = 0.06 * toe_w(a) * _smooth((f - 0.7) / 0.3)
        heel = 0.012 * max(0.0, math.cos(a + d * math.pi / 2)) ** 2 * _smooth((c.instep_z - z) / 0.4)
        return lift0 + 0.008 * math.sin(f * math.pi) + 0.004 * math.sin(a * 9 + z * 5) + flare + heel

    # columns go once round from the parting's front edge (u = 0) to its back edge (u = 1), with
    # extra columns round the peak at the brooch; rows from the top hem (tucked in) to the bottom
    # hem (tucked in)
    span = 2 * math.pi - 2 * g_max
    u_pk = (0.7 - g_max) / span                   # the brooch (where the top edge peaks)
    us = sorted(set([j / 36 for j in range(37)] + [u_pk - 0.012, u_pk, u_pk + 0.012]))
    us = [u for i, u in enumerate(us) if i == 0 or u - us[i - 1] > 0.004]
    ws = [-1.0] + [(i / 11) ** 1.1 for i in range(12)] + [2.0]

    def ang(u, z):
        g = gap(z)
        return a_g + d * (g + u * (2 * math.pi - 2 * g))

    bm = bmesh.new()
    rows = []
    for w in ws:
        ww = min(max(w, 0.0), 1.0)
        row = []
        for u in us:
            a = ang(u, z_b)
            for _it in range(4):
                z = _lerp(z_hi(a), z_lo(a), ww)
                a = ang(u, z)
            if w < 0:
                p = c.surface(a, z_hi(a) + 0.005, -0.03)[0]
            elif w > 1:
                p = c.surface(a, z_lo(a), -0.03)[0]
            else:
                p = c.surface(a, z, lift(a, z))[0]
            row.append(p)
        closed = gap(_lerp(z_hi(a_g), z_lo(a_g), ww)) < 0.012
        verts = [bm.verts.new(p) for p in row[:-1]]
        verts.append(verts[0] if closed else bm.verts.new(row[-1]))
        rows.append(verts)
    pals = []
    for i in range(len(rows) - 1):
        for j in range(len(us) - 1):
            try:
                bm.faces.new((rows[i][j], rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1]))
            except ValueError:
                continue
            pals.append(toga2 if i in (0, len(rows) - 2) else toga)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _orient(bm, lambda q: _skeleton_origin(c, q))
    out = [_piece(bm, pals, True, True, "toga")]
    # ink along both edges of the parting (an open cloth edge lying flat draws no hull line)
    for u in (0.0, 1.0):
        pts, nrms = [], []
        z0 = z_hi(ang(u, z_top))
        for k in range(8):
            z = _lerp(z0 - 0.02, z_end + 0.03, k / 7)
            a = ang(u, z)
            z = min(z, z_hi(a) - 0.02)
            p, n = c.surface(a, z, lift(a, z) + 0.01)
            pts.append(p)
            nrms.append(n)
        out.append(_ribbon(pts, nrms, 0.03, taper=0.4, samples=2, name="togaedge"))
    # long fold lines fanning out from just under the brooch, down past the heel-side tufts of the
    # beard and across the front toward the toe side and the instep, as seen from the front:
    # (x toward the heel side, depth below z_b) control points
    folds = [((0.6, 0.26), (0.47, 0.5), (0.12, 0.74), (-0.36, 0.9)),
             ((0.63, 0.32), (0.52, 0.62), (0.12, 0.96), (-0.56, 1.2)),
             ((0.62, 0.4), (0.5, 0.8), (0.22, 1.12), (-0.16, 1.33))]
    for k, ctrl in enumerate(folds):
        pts, nrms = [], []
        for q in _catmull([(x * hs, z_b - dz * hs, 0.0) for x, dz in ctrl], 3):
            r = max(c.radius_at(q.y), 0.2)
            a = -d * math.asin(max(-0.97, min(0.97, q.x / r)))
            z = min(max(q.y, z_lo(a) + 0.1), z_hi(a) - 0.06)
            p, n = c.surface(a, z, lift(a, z) + 0.008)
            pts.append(p)
            nrms.append(n)
        out.append(_ribbon(pts, nrms, 0.035 if k < 2 else 0.03, pal=fold, taper=0.3, samples=2, name="fold"))
    # the brooch: a round gold disc on the cloth, facing halfway between the surface and the viewer
    zbr = z_b - 0.05
    p, n = c.surface(a_b, zbr, lift(a_b, zbr) + 0.045)
    face = (n + Vector((0.0, -1.0, 0.0))).normalized()
    t1, t2 = _frame(face)
    rot = Matrix((t1, t2, face)).transposed().to_4x4()
    out.append(K.sphere(gold, 1.0, Matrix.Translation(p) @ rot @ Matrix.Diagonal(Vector((0.2, 0.23, 0.08, 1))),
                        seg=14, rings=7, name="brooch"))
    out.append(K.sphere(gold2, 1.0, Matrix.Translation(p + face * 0.07 - t1 * 0.06 + t2 * 0.08) @ rot
                        @ Matrix.Diagonal(Vector((0.06, 0.075, 0.02, 1))), seg=8, rings=4, outline=False, name="shine"))

    def over(a, z):
        zh = z_hi(a)
        w = _smooth((zh + 0.07 - z) / 0.1)
        return 0.0 if w <= 0.0 else w * (lift(a, min(z, zh)) + 0.012)
    return out, over


def _corner_curve(items, samples=5):
    """A closed outline through [(x, y, sharp)]: smooth Catmull-Rom runs between the sharp points,
    which stay pointed corners (beard tufts: pointed tips, rounded notches)."""
    idx = [i for i, it in enumerate(items) if it[2]]
    n = len(items)
    out = []
    for k, i0 in enumerate(idx):
        i1 = idx[(k + 1) % len(idx)]
        run = [items[i0]]
        j = i0
        while True:
            j = (j + 1) % n
            run.append(items[j])
            if j == i1:
                break
        pts = _catmull([(x, y, 0.0) for x, y, _s in run], samples)
        out += [(p.x, p.y) for p in pts[:-1]]
    return out


def _beard(c, grey, over=None):
    """A big chunky grey beard: a bold cut-out shape inked all round (its edge stands well proud so
    the outline shows), a wavy top edge under the eyes with pointed sideburns rising to the
    outer-bottom corner of each eye, three pointed tufts slanting down and out on each side
    between rounded notches, two more along the bottom and a pointed tip. A cream two-lobed lip
    under a peaked moustache stroke sits on it. Where it hangs over the toga, the beard, its ink
    band and its skirt ride over the cloth (over(angle, z)), so its ink border stays on top."""
    hs = c.h / 4.2
    zt = c.ey - c.eye_rim_r - 0.08                 # top edge (middle), just under the eyes
    hb = 1.12 * hs                                 # top -> tip
    W = 0.8                                        # half width (arc length) at the cheeks
    # the viewer-right half (x across -1..1 in W, y down from zt in hb, True = a sharp point),
    # from the sideburn tip round the tufts to the tip; the left half mirrors it
    side = [(1.0, 0.02, False), (1.09, 0.25, True), (0.87, 0.3, False), (0.9, 0.42, False),
            (0.99, 0.56, True), (0.75, 0.58, False), (0.76, 0.69, False), (0.79, 0.83, True),
            (0.55, 0.8, False), (0.5, 0.9, False), (0.43, 1.0, True), (0.23, 0.93, False), (0.14, 1.02, False)]
    topl = [(0.8, 0.03), (0.62, 0.11), (0.42, 0.07), (0.2, 0.025)]
    burn = (0.93, -0.16)
    items = [(-burn[0], burn[1], True)] + [(-x, y, False) for x, y in topl] + [(0.0, 0.0, False)] + \
        [(x, y, False) for x, y in reversed(topl)] + [(burn[0], burn[1], True)] + side + [(0.0, 1.13, True)] + \
        [(-x, y, s) for x, y, s in reversed(side)]
    bnd = [(x * W, zt - y * hb) for x, y in _corner_curve(items, 4)]
    leg = _leg_map(c)

    def to3d(s, z, lf):
        extra = over(s / max(c.radius_at(z), 0.2), z) if over else 0.0
        return leg(s, z, lf + extra)

    def height(dist, u, v):
        f = max(0.0, min(1.0, (zt - v) / hb))      # 0 at the top .. 1 at the tip
        bulge = 0.2 + 0.12 * f
        return 0.075 + (bulge - 0.075) * _smooth(dist / 0.32)

    beard = _pillow(to3d, _axis_inside, bnd, height, grey, spacing=0.105, skirt=0.06, name="beard")
    # a bold ink band all round it (the hull alone hardly shows where the beard meets the leg)
    out = [beard, _outline_ring(to3d, _densify(bnd, 0.08), -0.03, 0.036, 0.03, name="beard_ink")]
    # the mouth: a cream two-lobed lip under a peaked moustache, drawn on the beard's front
    bm = bmesh.new()
    bm.from_mesh(beard.mesh)
    bvh = BVHTree.FromBMesh(bm)
    bm.free()

    def on_beard(x, z, lift):
        loc, nrm, _i, _dd = bvh.ray_cast(Vector((x, -3.0, z)), Vector((0.0, 1.0, 0.0)))
        if loc is None:
            p, n = c.face_point(x, z, 0.0)
            return p + n * lift, n
        if nrm.y > 0:
            nrm = -nrm
        return loc + nrm * lift, nrm

    mz = zt - hb * 0.29                            # bottom of the lip's two lobes
    mw = 0.23
    apex = 0.14

    def peak(x):                                   # 1 at the centre .. 0 at the corners: an inverted V
        x = min(abs(x), 1.0)                       # with a small rounded apex
        return 1.0 - (math.sqrt(x * x + apex * apex) - apex) / (math.sqrt(1 + apex * apex) - apex)

    def arch(u):                                   # the moustache line (the lip's top edge)
        return mz + 0.06 + 0.1 * peak(u / mw)

    def mouth(g):
        w = mw + g

        def bot(u):                                # two round lobes, a deep notch in the middle
            x = min(abs(u) / w, 1.0)
            return mz - g + (0.06 + g) * x ** 4 + 0.055 * math.exp(-(x / 0.2) ** 2)
        return -w, w, (lambda u: arch(u * mw / w) + g), bot
    out += _inked_plate(on_beard, mouth, c.body, border=0.026, lift=0.02, n=13)
    # the moustache: a heavy stroke along the lip's top, past both corners into short upturned flicks
    xs = [-1.28, -1.12, -1.0, -0.7, -0.38, -0.12, 0.0, 0.12, 0.38, 0.7, 1.0, 1.12, 1.28]
    pts, nrms = [], []
    for x in xs:
        z = arch(x * mw) if abs(x) <= 1.0 else arch(mw) + 0.035 * ((abs(x) - 1.0) / 0.28) ** 1.3
        p, n = on_beard(x * mw, z, 0.036)
        pts.append(p)
        nrms.append(n)
    out.append(_ribbon(pts, nrms, 0.045, taper=0.3, samples=2, name="moustache"))
    return out


def _leaf_blade(base, dirv, nrm, length, width, thick, pal, pal2, ink=0.022, arch=0.025, name="leaf"):
    """A plump almond leaf as a thin closed lens from `base` along dirv, its flat side facing nrm:
    the +side half of its top `pal`, the -side half and the underside `pal2` (the sheet's two-tone
    laurel, split along the midrib). Its ink comes from a hidden 'carrier': a smaller, wafer-thin
    copy inside it whose outline hull (the sock's outline width) ends up only `ink` past the leaf's
    edge - a light line that keeps small overlapping leaves readable (a hull of the leaf itself
    would be as heavy as the sock's outline), drawn by the shadowless outline object like every
    other line."""
    D = Vector(dirv).normalized()
    N = Vector(nrm)
    N = (N - D * N.dot(D)).normalized()
    S = D.cross(N).normalized()
    out = []
    shrink = OUTLINE_W - ink
    # cross-section angles: the top has a vertex on the midrib (90 deg), the underside is coarse
    for carrier, phis in ((False, [0.0, 50.0, 90.0, 130.0, 180.0, 270.0]), (True, [0.0, 90.0, 180.0, 270.0])):
        phis = [math.radians(x) for x in phis]
        seg = len(phis)
        bm = bmesh.new()
        rings = []
        for i in range(1, 4):
            t = i / 4
            prof = math.sin(math.pi * t ** 0.9) ** 0.85
            hw, ht = width / 2 * prof, thick / 2 * prof
            if carrier:
                hw, ht = max(hw - shrink, 0.006), 0.004
            ctr = base + D * (length * t) + N * (arch * math.sin(math.pi * t))
            rings.append([bm.verts.new(ctr + S * (hw * math.cos(ph)) + N * (ht * math.sin(ph))) for ph in phis])
        e = shrink if carrier else 0.0
        t0 = bm.verts.new(base + D * e)
        t1 = bm.verts.new(base + D * (length - e))
        pals = []

        def colour(k):
            ph = (phis[k] + phis[(k + 1) % seg] + (2 * math.pi if k == seg - 1 else 0.0)) / 2
            if math.sin(ph) < 0:
                return pal2
            return pal if math.cos(ph) > 0 else pal2
        for k in range(seg):
            k2 = (k + 1) % seg
            bm.faces.new((t0, rings[0][k2], rings[0][k]))
            pals.append(colour(k))
            bm.faces.new((t1, rings[-1][k], rings[-1][k2]))
            pals.append(colour(k))
        for ra, rb in zip(rings, rings[1:]):
            for k in range(seg):
                k2 = (k + 1) % seg
                bm.faces.new((ra[k], rb[k], rb[k2], ra[k2]))
                pals.append(colour(k))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        if carrier:
            out.append(_piece(bm, pal2, True, False, name + "_ink"))
        else:
            out.append(_piece(bm, pals, False, True, name))
    return out


def _wreath(c, leaf, leaf2, d):
    """A laurel wreath worn tilted: on the heel side a big sprig runs from just under the rim near
    the middle of the face diagonally down across the upper heel-side quarter and round the side,
    its herringbone leaves standing off the leg as it passes the side so its end leaves stick out
    past the outline at eye-top height; on the toe side the branch ends in three leaves fanning out
    sideways past the outline at eye-top height. Behind, both branches meet low at the back, with
    smaller leaves lying close to the leg. Every leaf is a plump two-tone blade inked by a thin
    outline; nothing rises above the rim."""
    out = []
    hs = c.h / 4.2
    h = c.h
    z_eye_top = c.ey + c.eye_rim_r
    z_back = z_eye_top - 0.12 * hs

    def deg(a):
        return math.radians(a)

    # each branch: (angle in degrees from the face toward its side, z), back -> front. The heel
    # sprig's front part falls evenly in a front view (z linear in sin(angle)), a ~30 deg diagonal
    def diag(a_):                                  # 0 at the front tip (10 deg) .. 1 at the side
        return (math.sin(deg(a_)) - math.sin(deg(10.0))) / (1.0 - math.sin(deg(10.0)))
    heel = [(180.0, z_back), (140.0, z_back + 0.02), (110.0, z_eye_top - 0.01)] + \
        [(a_, h - (0.12 + 0.36 * diag(a_)) * hs) for a_ in (85.0, 62.0, 42.0, 24.0, 10.0)]
    toe = [(180.0, z_back), (145.0, z_back + 0.02), (115.0, z_eye_top - 0.02), (92.0, z_eye_top + 0.02)]

    def branch_fn(ctrl, s):
        pts = _catmull([(a_, z, 0.0) for a_, z in ctrl], 10)

        def z_at(adeg):                            # the branch height at |angle| adeg
            for p_, q_ in zip(pts, pts[1:]):
                if min(p_.x, q_.x) <= adeg <= max(p_.x, q_.x) and abs(q_.x - p_.x) > 1e-9:
                    return _lerp(p_.y, q_.y, (adeg - p_.x) / (q_.x - p_.x))
            return pts[0].y if adeg > pts[0].x else pts[-1].y

        def at(adeg, lift=0.0):
            a_ = s * deg(adeg)
            return c.surface(a_, z_at(adeg), lift)
        return at, pts[-1].x

    for s, ctrl in ((-d, heel), (d, toe)):
        at, a_tip = branch_fn(ctrl, s)
        heel_side = s == -d
        # leaf nodes: |angle| in degrees, sides (1 above the stem, -1 below, 0 along it), size
        if heel_side:
            nodes = [(165.0, (1, -1), 0.78), (135.0, (1, -1), 0.82), (106.0, (1, -1), 1.0), (88.0, (1, -1), 1.05),
                     (70.0, (1, -1), 1.05), (52.0, (1, -1), 1.0), (35.0, (1, -1), 0.95), (19.0, (1, -1, 0), 0.9)]
        else:
            nodes = [(165.0, (1, -1), 0.78), (138.0, (1, -1), 0.8), (114.0, (1, -1), 0.85), (95.0, (1, -1, 0), 1.0)]
        for adeg, sides, sz in nodes:
            p, n = at(adeg)
            p2 = at(adeg - 3.0)[0]
            p1 = at(adeg + 3.0)[0]
            tang = (p2 - p1).normalized()          # toward the front tip
            upv = n.cross(tang).normalized()
            if upv.z < 0:
                upv = -upv
            # leaves stand off the leg as the branch passes the side (the outline in a front view)
            tilt = deg(12.0 + 26.0 * _smooth((adeg - 45.0) / 25.0) * _smooth((130.0 - adeg) / 25.0))
            L = 0.34 * hs * sz
            Wd = 0.56 * L
            end = not heel_side and adeg < 100.0
            for sd in sides:
                spread = 42.0 if sd else 0.0
                d0 = (tang * math.cos(deg(spread)) + upv * (sd * math.sin(deg(spread)))).normalized()
                dv = (d0 * math.cos(tilt) + n * math.sin(tilt)).normalized()
                kf = _smooth((adeg - 40.0) / 30.0) * _smooth((150.0 - adeg) / 30.0)
                lift_n = (n * (1.0 - kf) + Vector((0.0, -1.0, 0.0)) * kf).normalized()
                if end:                            # the toe-side end: three leaves fanning out sideways
                    out_h = Vector((n.x, n.y, 0.0)).normalized()
                    e = deg({1: 50.0, 0: 14.0, -1: -24.0}[sd])
                    dv = (out_h * math.cos(e) + Vector((0.0, 0.0, math.sin(e))) + tang * 0.25).normalized()
                    lift_n = Vector((0.0, -1.0, 0.0))
                tipz = p.z + dv.z * L              # never above the rim
                if tipz > h - 0.05:
                    dv = (dv - Vector((0.0, 0.0, (tipz - (h - 0.05)) / L))).normalized()
                lift_n = (lift_n - dv * lift_n.dot(dv)).normalized()
                base = p + n * 0.02 - tang * 0.015
                out += _leaf_blade(base, dv, lift_n, L, Wd, 0.045, leaf, leaf2, name="leaf")
        stem = [at(_lerp(178.0, a_tip + 4.0, k / 10), 0.012) for k in range(11)]
        out.append(_ribbon([p for p, _n in stem], [n for _p, n in stem], 0.024, pal=leaf2, taper=0.6,
                           samples=2, name="stem"))
    return out


# Per-type tweaks merged over socks.SPECS (colours, mood, tall/short, ...). Never change `single`.
# Tubolino: its sad face (droopy lids + frown) is drawn here, so the shared face draws no mouth/brows.
# Sockrates: the mouth is drawn on the beard.
SPEC_OVERRIDES = {
    # measured on the sheet: two equal stripes ~0.16 thick with a ~0.14 gap, the lower one running
    # behind the eye tops (the band is cut down to 0.12 so region() can't paint over the upper
    # stripe - with cuff="body" it is invisible anyway), the face ~0.9 below the rim, a toe band
    # ~0.12 of the leg width
    "Tubolino": dict(mood="calm", mouth=False, face_drop=0.88, cuff_h=0.12,
                     stripes=[(3.72, 3.92, "accent"), (3.33, 3.53, "accent")], toe_stripe=(0.15, 0.18, "accent")),
    "Sockrates": dict(mouth=False),
    # the fangs grin is redrawn a little higher by feat_anklebiter
    "AnkleBiter": dict(mouth=False),
    # a hotter pink than AnkleBiter's, so the two pink socks are told apart at a glance
    "ToeToe": dict(body="#FF7EB8", dark="#E9579A"),
    # the face a little lower than the default, so a strip of mint shows between the band and the eyes
    "GymGary": dict(face_drop=0.98),
}

FEATURES = {
    "Tubolino": feat_tubolino,
    "AnkleBiter": feat_anklebiter,
    "CrustyCrew": feat_crusty,
    "GymGary": feat_gymgary,
    "Argylo": feat_argylo,
    "ToeToe": feat_toetoe,
    "Sockrates": feat_sockrates,
}
