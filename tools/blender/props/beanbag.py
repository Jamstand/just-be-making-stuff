"""
props/beanbag.py - the BeanBag prop (ReplicatedStorage.MapMeshes.BeanBag): a big squishy teal bean
bag chair slumped on the bedroom floor, a little yellow star plush (bead eyes, pink cheeks, a smile)
leaning back in its seat and an open comic book lying face-down beside it. See props/__init__.py for
the conventions every prop follows.

No concept art shows it, so it is designed to sit in docs/concept/bedroom_keyframe.png: chunky soft
toy shapes, flat 2-3 tone colours, thick ink lines.
The sack: a signed-distance blob (a wide squashed ball spreading on the floor and a backrest lobe
leaning back, smooth-unioned, the floor cutting it flat) sampled along rays from a point inside it,
on a latitude / longitude grid whose pole points at the top of the backrest. Like a real pear bean
bag it is sewn from six gores: each seam is one meridian of that grid, pulled in a little so the
panels between them puff out, with a darker piping cord laid in it; the gores meet at a round top
panel (piping round it, a carry loop on it). Then a soft dent is pressed into the seat where you'd
sit (only the upward-facing fabric sinks, so the sides keep their bulge). Everything laid on the
fabric (piping, loop, book) goes through the same mapping, so it follows the dent and the gores.
Fabric tones (lit / base / shade / deep) are cut along smooth iso-lines of the normal's z.

Units: 1 unit = 10 studs. Map fits the model uniformly into 120 x 80 x 110 studs (W x H x D); the
model is about 11.3 x 7.9 x 10.6 units (W x H x D). Origin = floor centre, front faces -Y.
"""
import math
import bmesh
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
import sockkit as K
from sockkit import M, hexcol

NAME = "BeanBag"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"beanbag_fabric": "fur", "beanbag_star": "fur", "beanbag_star_cheek": "felt"}  # plush sack, plush star

FAB = (hexcol("beanbag_fabric_light", "#7EE3E2"),   # top-facing fabric
       hexcol("beanbag_fabric", "#34BDC6"),         # most of the sack
       hexcol("beanbag_fabric_shade", "#2393AE"),   # sides turning away / under the bulge
       hexcol("beanbag_fabric_deep", "#1C6F92"))    # the underside rolling onto the floor
PIPE = (hexcol("beanbag_piping_light", "#2C86A6"), hexcol("beanbag_piping", "#185E80"))
# the comic book
COV_Y = (hexcol("beanbag_comic_yellow_light", "#FFE66B"), hexcol("beanbag_comic_yellow", "#FFC93A"))
COV_R = (hexcol("beanbag_comic_red_light", "#FF6F5E"), hexcol("beanbag_comic_red", "#E8453C"))
COV_B = hexcol("beanbag_comic_blue", "#3F6FD8")
COV_W = hexcol("beanbag_comic_white", "#FFF8EC")
PAGES = (hexcol("beanbag_pages", "#F6EBD3"), hexcol("beanbag_pages_dark", "#D8C7A6"))
# the star plush
STAR = (hexcol("beanbag_star_light", "#FFE98C"), hexcol("beanbag_star", "#FFCB3B"),
        hexcol("beanbag_star_shade", "#E79F2A"))
STAR_CUTS = (-0.25, 0.6)
EYE = hexcol("beanbag_star_eye", "#2A1A2E")
CHEEK = hexcol("beanbag_star_cheek", "#FF9AAE")
SMILE = hexcol("beanbag_star_smile", "#6B2F2A")

OUTLINE_W = 0.13                 # ~1.1% of the bag's width, ~1.7% of its height
FAB_CUTS = (-0.62, -0.2, 0.72)   # normal z: deep / shade / base / lit
RAY_C = np.array((0.0, 0.6, 2.8))  # every fabric point is found on a ray from here
CROWN = Vector((0.22, 2.55, 7.6)) - Vector(RAY_C)  # the grid's pole: the top of the backrest
# gore seam longitudes (degrees; 90 = the back, 270 = the front): the front gore, stretched over the
# seat, is the widest
SEAMS = (0.0, 60.0, 120.0, 180.0, 228.0, 312.0)
GROOVE, GROOVE_W = 0.2, 0.2      # seam groove depth (units) and half width (radians of longitude)
CAP = 0.26                       # polar angle (radians) of the top panel's edge
DENT = ((-0.1, -0.8), (3.0, 2.55), 1.75)  # seat dent: centre (x, y), radii, depth


# ---------------------------------------------------------------- the field
def _smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b * (1 - h) + a * h - k * h * (1 - h)


def _smax(a, b, k):
    return -_smin(-a, -b, k)


def _ellipsoid(P, c, r, tilt=0.0, yaw=0.0):
    """Approximate signed distance to an ellipsoid (centre c, semi-axes r), tilted about X (top
    toward +Y for tilt > 0) and turned about Z."""
    Q = P - np.asarray(c, dtype=float)
    if yaw:
        cy, sy = math.cos(yaw), math.sin(yaw)
        Q = np.stack((cy * Q[:, 0] + sy * Q[:, 1], -sy * Q[:, 0] + cy * Q[:, 1], Q[:, 2]), axis=1)
    if tilt:
        ct, st = math.cos(tilt), math.sin(tilt)
        Q = np.stack((Q[:, 0], ct * Q[:, 1] - st * Q[:, 2], st * Q[:, 1] + ct * Q[:, 2]), axis=1)
    r = np.asarray(r, dtype=float)
    k0 = np.linalg.norm(Q / r, axis=1)
    k1 = np.maximum(np.linalg.norm(Q / (r * r), axis=1), 1e-9)
    return k0 * (k0 - 1.0) / k1


def _sdf(P):
    """The undented sack (negative inside), for points P (N x 3, units). Star-shaped from RAY_C."""
    P = np.asarray(P, dtype=float).reshape(-1, 3)
    seat = _ellipsoid(P, (0.0, -0.4, 2.1), (5.3, 4.8, 2.5), yaw=0.05)
    spread = _ellipsoid(P, (0.0, -0.15, 0.85), (5.75, 5.3, 1.3))
    back = _ellipsoid(P, (0.2, 2.1, 4.3), (3.7, 2.6, 3.5), tilt=0.32, yaw=-0.08)
    f = _smin(seat, spread, 1.2)
    f = _smin(f, back, 1.8)
    return _smax(f, -P[:, 2], 0.5)  # the floor flattens the bottom


def _grad(P, e=1e-3):
    P = np.asarray(P, dtype=float).reshape(-1, 3)
    g = np.empty_like(P)
    for i in range(3):
        d = np.zeros(3)
        d[i] = e
        g[:, i] = (_sdf(P + d) - _sdf(P - d)) / (2 * e)
    return g / np.maximum(np.linalg.norm(g, axis=1, keepdims=True), 1e-9)


def _ray_hit(D):
    """Where rays from RAY_C along D (N x 3) leave the undented sack."""
    D = np.asarray(D, dtype=float).reshape(-1, 3)
    D = D / np.linalg.norm(D, axis=1, keepdims=True)
    ts = np.arange(0.0, 12.0, 0.05)
    f = _sdf((RAY_C[None, None, :] + ts[None, :, None] * D[:, None, :]).reshape(-1, 3)).reshape(len(D), len(ts))
    k = np.argmax(f > 0, axis=1)
    lo, hi = ts[np.maximum(k - 1, 0)], ts[k]
    for _ in range(18):
        mid = (lo + hi) / 2
        out = _sdf(RAY_C + mid[:, None] * D) > 0
        hi = np.where(out, mid, hi)
        lo = np.where(out, lo, mid)
    return RAY_C + ((lo + hi) / 2)[:, None] * D


ALPHA = math.atan2(CROWN.y, CROWN.z)  # how far the crown leans back from straight up


def _dirs(theta, phi):
    """World ray directions for polar angle theta (from the crown) and longitude phi (arrays; 90
    degrees = the back). The grid's pole leans back to the crown; lower down the lean fades out, so
    under the sack the meridians run straight down to a pole right under RAY_C (seams then meet
    the floor square instead of sliding round the front)."""
    theta, phi = np.broadcast_arrays(np.asarray(theta, dtype=float), np.asarray(phi, dtype=float))
    theta, phi = theta.reshape(-1), phi.reshape(-1)
    x, y, z = np.sin(theta) * np.cos(phi), np.sin(theta) * np.sin(phi), np.cos(theta)
    s = np.clip((theta - 1.1) / 1.3, 0.0, 1.0)
    a = ALPHA * (1 - s * s * (3 - 2 * s))
    return np.stack((x, y * np.cos(a) + z * np.sin(a), -y * np.sin(a) + z * np.cos(a)), axis=1)


def _seam_dist(phi):
    """Longitude distance (radians) to the nearest gore seam."""
    phi = np.asarray(phi, dtype=float)
    d = np.full(phi.shape, np.inf)
    for s in SEAMS:
        a = np.mod(phi - math.radians(s), math.tau)
        d = np.minimum(d, np.minimum(a, math.tau - a))
    return d


def _surface(theta, phi, lift=0.0):
    """The finished fabric surface at grid coordinates (theta, phi): ray hit on the blob, pulled in
    along the seams, pressed down by the seat dent. `lift` moves the point out along the blob's
    normal (before the dent) - for things laid on the fabric."""
    theta, phi = np.broadcast_arrays(np.asarray(theta, dtype=float), np.asarray(phi, dtype=float))
    theta, phi = theta.reshape(-1), phi.reshape(-1)
    H = _ray_hit(_dirs(theta, phi))
    N = _grad(H)
    # gores: the seams sink in (fading out on the top panel and under the floor line)
    g = np.exp(-(_seam_dist(phi) / GROOVE_W) ** 2)
    g *= np.clip((theta - CAP) / 0.25, 0.0, 1.0)
    g *= np.clip(H[:, 2] / 0.8, 0.0, 1.0)
    H = H - N * (GROOVE * g)[:, None] + N * lift
    # the seat dent: upward-facing fabric sinks (a smooth bowl), the sides keep their bulge
    (cx, cy), (rx, ry), depth = DENT
    w = np.exp(-(((H[:, 0] - cx) / rx) ** 2 + ((H[:, 1] - cy) / ry) ** 2))
    up = np.clip((N[:, 2] - 0.15) / 0.55, 0.0, 1.0)
    H[:, 2] -= depth * w * up * up * (3 - 2 * up)
    return H


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


def _tone(cols, nz, cuts=FAB_CUTS):
    if nz > cuts[2]:
        return cols[0]
    if nz > cuts[1]:
        return cols[1]
    if nz > cuts[0] or len(cols) < 4:
        return cols[2]
    return cols[3]


def _outward(bm):
    """Turns a closed mesh's faces outward (by its signed volume)."""
    vol = 0.0
    for f in bm.faces:
        vs = [v.co for v in f.verts]
        for i in range(1, len(vs) - 1):
            vol += vs[0].dot(vs[i].cross(vs[i + 1]))
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])


def _tube(points, radius, sides, pal, name, closed=False, outline=True, radii=None):
    """A tube through `points` (parallel-transport frames), closed into a ring or capped flat at both
    ends; pal(normal) -> palette index."""
    bm = bmesh.new()
    pts = [Vector(p) for p in points]
    n = len(pts)
    rings, nv = [], None
    for i in range(n):
        if closed:
            t = (pts[(i + 1) % n] - pts[i - 1]).normalized()
        else:
            t = (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized()
        nv = t.orthogonal().normalized() if nv is None else (nv - t * nv.dot(t)).normalized()
        b = t.cross(nv)
        r = radius * (radii[i] if radii else 1.0)
        rings.append([bm.verts.new(pts[i] + (nv * math.cos(a) + b * math.sin(a)) * r)
                      for a in (j / sides * math.tau for j in range(sides))])
    for i in range(n if closed else n - 1):
        a, b = rings[i], rings[(i + 1) % n]
        shift = 0
        if closed and i == n - 1:  # the transported frame may come back turned: join the nearest
            shift = min(range(sides), key=lambda s: (a[0].co - b[s].co).length)
        for j in range(sides):
            k = (j + 1) % sides
            bm.faces.new((a[j], b[(j + shift) % sides], b[(k + shift) % sides], a[k]))
    if not closed:
        bm.faces.new(rings[0][::-1])
        bm.faces.new(rings[-1])
    _outward(bm)
    bm.normal_update()
    fp = [pal(f.normal) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, name), fp, outline, True, name)


def _pipe_pal(nrm):
    return PIPE[0] if nrm.z > 0.55 else PIPE[1]


# ---------------------------------------------------------------- the sack
def _longitudes(col=math.radians(8.0)):
    """Grid longitudes: a vertex column on every seam, the gores split evenly in between."""
    seams = sorted(math.radians(s) for s in SEAMS)
    out = []
    for i, a in enumerate(seams):
        b = seams[(i + 1) % len(seams)] + (math.tau if i == len(seams) - 1 else 0.0)
        n = max(4, round((b - a) / col))
        out += [a + (b - a) * j / n for j in range(n)]
    return np.array(out)


def _sack(rings=26):
    # polar angles: finer near the crown (the top panel) and round the floor line
    th = np.array([math.pi * (i / rings) ** 1.08 for i in range(1, rings)])
    ph = _longitudes()
    seg = len(ph)
    T, P = np.meshgrid(th, ph, indexing="ij")
    S = _surface(T, P)
    top = _surface(np.array([0.0]), np.array([0.0]))[0]
    bot = _surface(np.array([math.pi]), np.array([0.0]))[0]
    bm = bmesh.new()
    grid = [[bm.verts.new(tuple(S[i * seg + j])) for j in range(seg)] for i in range(len(th))]
    vt, vb = bm.verts.new(tuple(top)), bm.verts.new(tuple(bot))
    for j in range(seg):
        k = (j + 1) % seg
        bm.faces.new((vt, grid[0][j], grid[0][k]))
        bm.faces.new((vb, grid[-1][k], grid[-1][j]))
        for i in range(len(th) - 1):
            bm.faces.new((grid[i][j], grid[i + 1][j], grid[i + 1][k], grid[i][k]))
    # the bottom is flat on the floor: clamp what the sampling left a hair below it
    for v in bm.verts:
        v.co.z = max(v.co.z, 0.0)
    _outward(bm)
    bm.normal_update()
    nz = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, nz, FAB_CUTS)
    fp = [_tone(FAB, sum(nz[v] for v in f.verts) / len(f.verts)) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, "sack"), fp, True, True, "sack")


def _seams():
    """Piping along the six gore seams (from the top panel down to the floor) and round the top panel."""
    out = []
    r = 0.15
    for deg in SEAMS:
        phi = math.radians(deg)
        th = np.linspace(CAP, math.pi * 0.98, 34)
        S = _surface(th, np.full_like(th, phi), lift=r * 0.35)
        # follow it down the side; stop where the fabric starts rolling under toward the floor
        keep, far = [], 0.0
        for p in S:
            rad = math.hypot(p[0] - RAY_C[0], p[1] - RAY_C[1])
            if p[2] < 1.6 and rad < far - 0.04:
                break
            far = max(far, rad)
            if not keep or (Vector(p) - Vector(keep[-1])).length > r * 0.9:
                keep.append(tuple(p))
        radii = [1.0] * (len(keep) - 3) + [0.8, 0.55, 0.3]   # tapered into the fold, no stub
        out.append(_tube(keep, r, 6, _pipe_pal, "seam", radii=radii))
    ph = np.linspace(0, math.tau, 36, endpoint=False)
    S = _surface(np.full_like(ph, CAP), ph, lift=r * 0.35)
    out.append(_tube([tuple(p) for p in S], r * 1.1, 6, _pipe_pal, "cap_piping", closed=True))
    return out


def _carry_loop():
    """A little fabric carry loop on the top panel, across the crown."""
    ph = (math.radians(15), math.radians(195))
    ends = _surface(np.array([CAP * 0.62, CAP * 0.62]), np.array(ph))
    a, b = Vector(ends[0]), Vector(ends[1])
    up = (CROWN.normalized() * 0.6 + Vector((0, 0.35, 0.8)).normalized() * 0.4).normalized()
    pts = []
    for i in range(9):
        t = i / 8
        q = a.lerp(b, t) + up * (0.62 * math.sin(math.pi * t) - 0.08)
        pts.append(tuple(q))
    return _tube(pts, 0.12, 6, _pipe_pal, "carry_loop", radii=[0.9, 1, 1, 1, 1, 1, 1, 1, 0.9])


# ---------------------------------------------------------------- the comic book
def _frame(p, n, yaw):
    """Matrix: local z along n, local x turned `yaw` about it, origin p."""
    z = n.normalized()
    x = Vector((math.cos(yaw), math.sin(yaw), 0.0))
    x = (x - z * x.dot(z)).normalized()
    y = z.cross(x)
    return Matrix.Translation(p) @ Matrix((x, y, z)).transposed().to_4x4()


def _comic(bvh):
    """An open comic book lying face-down on the seat, tented over its spine: a yellow front cover
    with a blue title band and a red burst, a red back cover with a yellow strip, cream pages."""
    out = []
    loc, nrm, _i, _d = bvh.ray_cast(Vector((1.55, -2.1, 20.0)), Vector((0, 0, -1)))
    nrm = (nrm + Vector((0, 0, 1.5))).normalized()   # sit it a little flatter than the dent's slope
    fr = _frame(loc + nrm * 0.12, nrm, -0.35)
    half_w, h, cov_t, pag_t = 1.9, 2.75, 0.07, 0.2
    tilt = math.radians(22)
    rise = math.sin(tilt) * half_w + 0.02
    for side in (-1, 1):
        # this half: hinged at the spine (local x = 0, z = rise), sloping down toward local x = side
        hm = fr @ M((0, 0, rise), (0, side * tilt, 0))
        upv = (hm.to_3x3() @ Vector((0, 0, 1))).normalized()
        cover = K.rounded_box(COV_Y[1], (half_w, h, cov_t), hm @ M((side * half_w / 2, 0, cov_t / 2)), bevel=0.03,
                              segments=1, name="cover")
        cols = COV_Y if side < 0 else COV_R
        cover.face_pal = [cols[0] if f.normal.dot(upv) > 0.5 else cols[1] for f in cover.mesh.polygons]
        cover.smooth = False
        out.append(cover)
        pages = K.rounded_box(PAGES[0], (half_w - 0.12, h - 0.16, pag_t),
                              hm @ M((side * (half_w / 2 - 0.02), 0, -pag_t / 2 + 0.005)), bevel=0.03, segments=1,
                              name="pages")
        pages.face_pal = [PAGES[1] if f.normal.dot(upv) < -0.5 else PAGES[0] for f in pages.mesh.polygons]
        pages.smooth = False
        out.append(pages)
        top = hm @ M((0, 0, cov_t + 0.012))
        if side < 0:
            # front cover: title band along the top edge, a red burst with a white centre
            out.append(_flat_poly([(-half_w + 0.15, h / 2 - 0.15), (-0.14, h / 2 - 0.15), (-0.14, h / 2 - 0.65),
                                   (-half_w + 0.15, h / 2 - 0.65)], top, COV_B, "title"))
            c = (-half_w * 0.52, -0.3)
            out.append(_flat_poly(_burst(c, 0.72, 0.46, 9), top, COV_R[1], "burst"))
            out.append(_flat_poly(_burst(c, 0.34, 0.26, 9), top @ M((0, 0, 0.006)), COV_W, "burst_in"))
        else:
            y0, y1 = -h / 2 + 0.25, -h / 2 + 0.62
            out.append(_flat_poly([(0.14, y0), (half_w - 0.15, y0), (half_w - 0.15, y1), (0.14, y1)], top, COV_Y[1],
                                  "back_strip"))
    spine = K.cylinder(COV_R[1], 0.075, h, fr @ M((0, 0, rise + 0.03), (math.pi / 2, 0, 0)), seg=8, name="spine")
    out.append(spine)
    return out


def _burst(c, r_out, r_in, n):
    return [(c[0] + (r_out if i % 2 == 0 else r_in) * math.cos(i * math.pi / n + 0.2),
             c[1] + (r_out if i % 2 == 0 else r_in) * math.sin(i * math.pi / n + 0.2)) for i in range(2 * n)]


def _flat_poly(loop, mat, pal, name):
    """A flat filled polygon on local z = 0 of `mat`, facing local +z, no outline."""
    bm = bmesh.new()
    vs = [bm.verts.new((x, y, 0.0)) for x, y in loop]
    edges = [bm.edges.new((vs[i], vs[(i + 1) % len(vs)])) for i in range(len(vs))]
    bmesh.ops.triangle_fill(bm, use_beauty=True, use_dissolve=False, edges=edges, normal=(0, 0, 1))
    for f in bm.faces:
        if f.normal.z < 0:
            f.normal_flip()
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline=False, smooth=False, name=name)


# ---------------------------------------------------------------- the star plush
STAR_R = (0.66, 1.55)   # inner / outer radius of the star (units)
STAR_T = 0.62           # half thickness at its centre


def _star_r(a):
    c = (1 + math.cos(5 * (a - math.pi / 2))) / 2
    return STAR_R[0] + (STAR_R[1] - STAR_R[0]) * c ** 1.5


def _star_local(x, y, z):
    """Unit sphere (pole on z) -> puffy star in its own frame: star in the XZ plane, thickness on Y,
    face toward -Y."""
    a = math.atan2(y, x)
    r = _star_r(a)
    return Vector((x * r, z * STAR_T, y * r))


def _star_front(px, pz, lift=0.0):
    """Point on the star's front face (local) at in-plane (px, pz)."""
    a = math.atan2(pz, px)
    rn = math.hypot(px, pz) / _star_r(a)
    return Vector((px, -STAR_T * math.sqrt(max(0.0, 1 - rn * rn)) - lift, pz))


def _star_plush(bvh):
    """A little yellow star plush sitting in the seat dent, leaning back against the backrest, with
    two bead eyes, pink cheeks and a small smile."""
    out = []
    m = M((-1.55, -0.35, 0.0), (math.radians(-28), math.radians(-12), math.radians(14)))
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=40, v_segments=10, radius=1.0)
    for v in bm.verts:
        v.co = m @ _star_local(*v.co)
    # drop it onto the fabric: the lowest gap between a star vertex and the sack under it closes
    gaps = []
    for v in bm.verts:
        hit = bvh.ray_cast(v.co + Vector((0, 0, 20.0)), Vector((0, 0, -1)))[0]
        if hit is not None:
            gaps.append(v.co.z - hit.z)
    drop = min(gaps) - 0.05
    bmesh.ops.translate(bm, vec=Vector((0, 0, -drop)), verts=bm.verts)
    m = Matrix.Translation((0, 0, -drop)) @ m
    _outward(bm)
    bm.normal_update()
    nz = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, nz, STAR_CUTS)
    fp = [_tone(STAR, sum(nz[v] for v in f.verts) / len(f.verts), (-9, STAR_CUTS[0], STAR_CUTS[1]))
          for f in bm.faces]
    out.append(K.Piece(K._bm_to_mesh(bm, "star"), fp, True, True, "star"))
    for sx in (-1, 1):
        c = _star_front(sx * 0.27, 0.16, 0.0)
        eye = K.sphere(EYE, 1.0, m @ M(c, scale=(0.09, 0.07, 0.14)), seg=10, rings=6, outline=False, name="eye")
        out.append(eye)
        g = _star_front(sx * 0.27 - 0.03, 0.22, 0.06)
        out.append(K.sphere(K.WHITE, 0.035, m @ M(g), seg=6, rings=4, outline=False, name="glint"))
        ck = _star_front(sx * 0.46, -0.06, 0.012)
        out.append(K.cylinder(CHEEK, 0.11, 0.01, m @ M(ck, (math.pi / 2, 0, 0), (1.0, 0.7, 1.0)), seg=10,
                              outline=False, name="cheek"))
    smile = [tuple(m @ _star_front(x, -0.04 - 0.09 * math.cos(x / 0.14 * math.pi / 2), 0.02))
             for x in (-0.14, -0.07, 0.0, 0.07, 0.14)]
    out.append(K.tube(SMILE, smile, radius=0.028, res=2, bevel_res=1, outline=False, name="smile"))
    return out


# ---------------------------------------------------------------- build
def _no_bounce(outline):
    """Preview only (Cycles ray flags, not exported): the inverted hull must not block bounce light."""
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission"):
        if hasattr(outline, attr):
            setattr(outline, attr, False)


def build():
    sack = _sack()
    me = sack.mesh
    bvh = BVHTree.FromPolygons([v.co.copy() for v in me.vertices], [tuple(p.vertices) for p in me.polygons])
    p = [sack, _carry_loop()]
    p += _seams()
    p += _comic(bvh)
    p += _star_plush(bvh)
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    _no_bounce(outline)
    return [body, outline] + K.markers(NAME)
