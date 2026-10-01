"""
sockfeat_b.py - signature features for KneeHigh, Slipperino, Compressio, Sockhopper, DJDryer, Socktopus, Sockington.

Each feature builder takes the SockCtx `c` built by socks.py (body shape, eye/mouth positions,
surface helpers, colours) and returns a list of sockkit Pieces added on top of the shared body.
Only rely on SockCtx fields - never hard-code body dimensions - so the body can be reshaped without
breaking the features. Colour names must be prefixed with the type id (first registration wins).

Sheet socks (docs/concept/sock_character_sheet.png): Sockhopper rides a red pogo stick (black
grips with a steel sleeve, a long narrow red bar under the front of the foot that the toe rests
on, a steel shaft and a chunky black rubber tip); Socktopus's sack hangs on six chunky tentacles,
each a little sock of its own (a body-coloured leg, a heel corner, a foot, a fat toe, darker heel
and toe patches cut in as clean curves). The others are designed in the same style.
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
import sockkit as K
from sockkit import M, color, hexcol  # noqa: F401
import socks as S
from socks import (C_BLUEBOLT, C_CASH, C_DARK, C_GOLD, C_GOLD2, C_GREEN, C_GREY, C_MAGENTA,  # noqa: F401
                   C_PINKMOUTH, C_RED, C_SILVER, C_SILVER2, C_STINK, C_TONGUE, C_WICKER, C_WICKER2)

TAU = math.tau
Z = Vector((0.0, 0.0, 1.0))
Y = Vector((0.0, 1.0, 0.0))
_lerp, _smooth = S._lerp, S._smooth


# ------------------------------------------------------------------ geometry helpers
def _piece(bm, pals, name, outline=True, smooth=True):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pals, outline, smooth, name)


def _resample(pts, radii, samples):
    """Catmull-Rom through pts (samples per segment) with radii eased between the given points."""
    pts = [Vector(p) for p in pts]
    if samples <= 1 or len(pts) < 2:
        return pts, list(radii)
    P = S._catmull(pts, samples)
    R = [radii[0]]
    for k in range(1, len(P)):
        i, f = (k - 1) // samples, ((k - 1) % samples + 1) / samples
        R.append(_lerp(radii[i], radii[i + 1], _smooth(f)))
    return P, R


def _sweep(pts, radii, pal, seg=12, samples=6, cap0=1.0, cap1=1.0, flat=1.0, up=None, fixed_up=False,
           pal_fn=None, outline=True, smooth=True, closed=False, cap_rings=3, name="sweep"):
    """A tube through pts with per-point radii and rotation-minimising frames. The cross-section is
    an ellipse: r * flat along the frame normal N (starts as `up` projected off the tangent; with
    fixed_up it stays that projection), r along B = T x N. cap0/cap1: None = open, 0 = flat, > 0 =
    a dome cap that long (in radii). closed: the path is a loop (pass dense pts, samples=1).
    pal_fn(s, ph, centre) -> palette index per face (s = 0..1 along the path, ph = 0..1 around)."""
    if closed:
        P, R = [Vector(p) for p in pts], list(radii)
    else:
        P, R = _resample(pts, radii, samples)
    m = len(P)
    if closed:
        T = [(P[(k + 1) % m] - P[(k - 1) % m]).normalized() for k in range(m)]
    else:
        T = [(P[min(k + 1, m - 1)] - P[max(k - 1, 0)]).normalized() for k in range(m)]
    ref = Vector(up) if up is not None else (Z.copy() if abs(T[0].z) < 0.9 else Vector((1.0, 0.0, 0.0)))
    N = [(ref - T[0] * ref.dot(T[0])).normalized()]
    for k in range(1, m):
        n = (ref if fixed_up else N[-1])
        N.append((n - T[k] * n.dot(T[k])).normalized())
    B = [T[k].cross(N[k]) for k in range(m)]
    acc = [0.0]
    for k in range(1, m):
        acc.append(acc[-1] + (P[k] - P[k - 1]).length)
    tot = max(acc[-1], 1e-9)
    sv = [a / tot for a in acc]
    bm = bmesh.new()
    phis = [TAU * j / seg for j in range(seg)]

    def ring(ctr, n, b, r):
        return [bm.verts.new(ctr + n * (math.cos(ph) * r * flat) + b * (math.sin(ph) * r)) for ph in phis]

    rings, svals, tips = [], [], [None, None]
    if not closed and cap0 is not None:
        if cap0 > 0:
            tips[0] = bm.verts.new(P[0] - T[0] * (R[0] * cap0))
            for q in range(cap_rings - 1, 0, -1):
                a = (math.pi / 2) * q / cap_rings
                rings.append(ring(P[0] - T[0] * (R[0] * cap0 * math.sin(a)), N[0], B[0], R[0] * math.cos(a)))
                svals.append(0.0)
        else:
            tips[0] = bm.verts.new(P[0])
    for k in range(m):
        rings.append(ring(P[k], N[k], B[k], R[k]))
        svals.append(sv[k])
    if not closed and cap1 is not None:
        if cap1 > 0:
            for q in range(1, cap_rings):
                a = (math.pi / 2) * q / cap_rings
                rings.append(ring(P[-1] + T[-1] * (R[-1] * cap1 * math.sin(a)), N[-1], B[-1], R[-1] * math.cos(a)))
                svals.append(1.0)
            tips[1] = bm.verts.new(P[-1] + T[-1] * (R[-1] * cap1))
        else:
            tips[1] = bm.verts.new(P[-1])
    pals = []

    def col(s, ph, f):
        return pal_fn(s, ph, f.calc_center_median()) if pal_fn else pal

    nr = len(rings)
    if tips[0] is not None:
        for j in range(seg):
            f = bm.faces.new((tips[0], rings[0][(j + 1) % seg], rings[0][j]))
            pals.append(col(-0.001, (j + 0.5) / seg, f))
    pairs = [(a, a + 1) for a in range(nr - 1)] + ([(nr - 1, 0)] if closed else [])
    for a, b in pairs:
        for j in range(seg):
            j2 = (j + 1) % seg
            f = bm.faces.new((rings[a][j], rings[a][j2], rings[b][j2], rings[b][j]))
            pals.append(col((svals[a] + svals[b]) / 2, (j + 0.5) / seg, f))
    if tips[1] is not None:
        for j in range(seg):
            f = bm.faces.new((rings[-1][j], rings[-1][(j + 1) % seg], tips[1]))
            pals.append(col(1.001, (j + 0.5) / seg, f))
    return _piece(bm, pals, name, outline, smooth)


def _tube_bm(P, R, seg=14, up=None, cap0=None, cap1=1.0, cap_rings=4):
    """A tube through the given (already dense) path points P with radii R and rotation-minimising
    frames, as a bmesh with a face int layer 'tag' = 0 (so socks._cut can cut colour borders into
    it). cap0/cap1: None = open, 0 = flat, > 0 = a dome that many radii long.
    -> (bm, info) where info[vert] = (ring centre, unit radial direction)."""
    P = [Vector(p) for p in P]
    m = len(P)
    T = [(P[min(k + 1, m - 1)] - P[max(k - 1, 0)]).normalized() for k in range(m)]
    ref = Vector(up) if up is not None else (Z.copy() if abs(T[0].z) < 0.9 else Vector((1.0, 0.0, 0.0)))
    N = [(ref - T[0] * ref.dot(T[0])).normalized()]
    for k in range(1, m):
        N.append((N[-1] - T[k] * N[-1].dot(T[k])).normalized())
    B = [T[k].cross(N[k]) for k in range(m)]
    bm = bmesh.new()
    bm.faces.layers.int.new("tag")
    info = {}
    phis = [TAU * j / seg for j in range(seg)]

    def ring(ctr, n, b, r):
        out = []
        for ph in phis:
            e = n * math.cos(ph) + b * math.sin(ph)
            v = bm.verts.new(ctr + e * r)
            info[v] = (ctr.copy(), e)
            out.append(v)
        return out

    rings, tips = [], [None, None]
    if cap0 is not None:
        if cap0 > 0:
            for q in range(cap_rings - 1, 0, -1):
                a = (math.pi / 2) * q / cap_rings
                rings.append(ring(P[0] - T[0] * (R[0] * cap0 * math.sin(a)), N[0], B[0], R[0] * math.cos(a)))
            tips[0] = bm.verts.new(P[0] - T[0] * (R[0] * cap0))
        else:
            tips[0] = bm.verts.new(P[0])
        info[tips[0]] = (P[0].copy(), -T[0])
    for k in range(m):
        rings.append(ring(P[k], N[k], B[k], R[k]))
    if cap1 is not None:
        if cap1 > 0:
            for q in range(1, cap_rings):
                a = (math.pi / 2) * q / cap_rings
                rings.append(ring(P[-1] + T[-1] * (R[-1] * cap1 * math.sin(a)), N[-1], B[-1], R[-1] * math.cos(a)))
            tips[1] = bm.verts.new(P[-1] + T[-1] * (R[-1] * cap1))
        else:
            tips[1] = bm.verts.new(P[-1])
        info[tips[1]] = (P[-1].copy(), T[-1].copy())
    if tips[0] is not None:
        for j in range(seg):
            bm.faces.new((tips[0], rings[0][(j + 1) % seg], rings[0][j]))
    for a, b in zip(rings, rings[1:]):
        for j in range(seg):
            j2 = (j + 1) % seg
            bm.faces.new((a[j], a[j2], b[j2], b[j]))
    if tips[1] is not None:
        for j in range(seg):
            bm.faces.new((rings[-1][j], rings[-1][(j + 1) % seg], tips[1]))
    return bm, info


def _cut_colour(bm, regions, base, name, outline=True, smooth=True):
    """Cuts every region border fn(p) = 0 into the mesh as a clean curve (socks._cut), then colours
    each face with the palette index of the first region whose fn(centre) < 0 (else `base`).
    regions: [(fn, pal)]. The bmesh needs the int face layer 'tag' (all 0)."""
    for fn, _pal in regions:
        S._cut(bm, fn)
    bm.normal_update()
    pals = []
    for f in bm.faces:
        cen = f.calc_center_median()
        pal = base
        for fn, pl in regions:
            if fn(cen) < 0:
                pal = pl
                break
        pals.append(pal)
    return _piece(bm, pals, name, outline, smooth)


def _lathe(profile, pal, seg=20, mat=None, pal_fn=None, outline=True, smooth=True, name="lathe", phase=0.0):
    """Surface of revolution about +Z from (r, z) points listed bottom -> top along the outside
    (r = 0 makes a pole). pal_fn(k, j, centre) colours faces (k = profile segment)."""
    bm = bmesh.new()
    rings = []
    for r, z in profile:
        if r <= 1e-6:
            rings.append(bm.verts.new((0.0, 0.0, z)))
        else:
            rings.append([bm.verts.new((r * math.cos(TAU * j / seg + phase), r * math.sin(TAU * j / seg + phase), z))
                          for j in range(seg)])
    pals = []
    for k in range(len(rings) - 1):
        A, B = rings[k], rings[k + 1]
        for j in range(seg):
            j2 = (j + 1) % seg
            if isinstance(A, list) and isinstance(B, list):
                vs = (A[j], A[j2], B[j2], B[j])
            elif isinstance(A, list):
                vs = (A[j], A[j2], B)
            else:
                vs = (A, B[j2], B[j])
            f = bm.faces.new(vs)
            pals.append(pal_fn(k, j, f.calc_center_median()) if pal_fn else pal)
    if mat is not None:
        bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    return _piece(bm, pals, name, outline, smooth)


def _puck(ctr, nrm, up, hw, hh, th, pal, p=2.0, bevel=0.3, bulge=0.0, seg=24, rings=3, pal_fn=None,
          outline=True, smooth=True, name="puck"):
    """A rounded slab: superellipse outline (half sizes hw x hh, exponent p) facing nrm, th thick,
    edges rounded by `bevel` (fraction of the outline), the front domed by `bulge`."""
    n = Vector(nrm).normalized()
    u = (Vector(up) - n * Vector(up).dot(n)).normalized()
    x = u.cross(n)
    prof = [(0.0, -th / 2)]
    for q in range(rings + 1):
        a = -math.pi / 2 + math.pi * q / rings
        prof.append((1.0 - bevel * (1.0 - math.cos(a)), th / 2 * math.sin(a)))
    prof.append((0.0, th / 2 + bulge))
    bm = bmesh.new()

    def outline_pt(ph):
        cph, sph = math.cos(ph), math.sin(ph)
        return (hw * math.copysign(abs(cph) ** (2 / p), cph), hh * math.copysign(abs(sph) ** (2 / p), sph))

    outl = [outline_pt(TAU * j / seg) for j in range(seg)]
    vr = []
    for sc, dz in prof:
        if sc <= 1e-6:
            vr.append(bm.verts.new(ctr + n * dz))
        else:
            bz = bulge * (1.0 - sc) if dz > 0 else 0.0
            vr.append([bm.verts.new(ctr + x * (ox * sc) + u * (oy * sc) + n * (dz + bz)) for ox, oy in outl])
    pals = []
    for k in range(len(vr) - 1):
        A, B = vr[k], vr[k + 1]
        for j in range(seg):
            j2 = (j + 1) % seg
            if isinstance(A, list) and isinstance(B, list):
                vs = (A[j], A[j2], B[j2], B[j])
            elif isinstance(A, list):
                vs = (A[j], A[j2], B)
            else:
                vs = (A, B[j2], B[j])
            f = bm.faces.new(vs)
            f.normal_update()
            pals.append(pal_fn(k, len(vr) - 1, f) if pal_fn else pal)
    return _piece(bm, pals, name, outline, smooth)


def _shell(c, nu, nv, grid, thick, pal, wrap=False, pal_fn=None, hole=None, surf=None, wall_pal=None,
           outline=True, smooth=True, name="shell"):
    """A closed slab over a surface: grid(u, v) -> (angle, z, lift) for u, v in 0..1 (u across, v
    along the rows); surf(angle, z) -> (point, normal) is the surface (default: the leg, c.surface).
    The inner face sits `lift` off it, the outer one `thick` further. wrap: u = 1 joins u = 0 (a
    ring). hole(i, k) -> True leaves cell (i, k) out (walls close the hole's border).
    pal_fn(u, v, centre) colours the outer faces; wall_pal the walls (default pal)."""
    surf = surf or c.surface
    wall_pal = pal if wall_pal is None else wall_pal
    bm = bmesh.new()
    cols = nu if wrap else nu + 1
    inner, outer, nrm = {}, {}, {}
    for i in range(cols):
        for k in range(nv + 1):
            a, z, lift = grid(i / nu, k / nv)
            p, n = surf(a, z)
            inner[i, k] = bm.verts.new(p + n * lift)
            outer[i, k] = bm.verts.new(p + n * (lift + thick))
            nrm[i, k] = n

    def I(i):
        return i % nu if wrap else i

    def inc(i, k):
        if k < 0 or k >= nv or (not wrap and (i < 0 or i >= nu)):
            return False
        return not (hole and hole(I(i), k))

    pals = []

    def face(vs, want, pal_):
        f = bm.faces.new(vs)
        f.normal_update()
        if f.normal.dot(want) < 0:
            f.normal_flip()
        pals.append(pal_)

    for i in range(nu):
        for k in range(nv):
            if not inc(i, k):
                continue
            q = [(I(i), k), (I(i + 1), k), (I(i + 1), k + 1), (I(i), k + 1)]
            nn = sum((nrm[t] for t in q), Vector())
            cen = sum((outer[t].co for t in q), Vector()) / 4
            face([outer[t] for t in q], nn, pal_fn((i + 0.5) / nu, (k + 0.5) / nv, cen) if pal_fn else pal)
            face([inner[t] for t in reversed(q)], -nn, pal)
            for ta, tb, ni, nk in ((q[0], q[1], i, k - 1), (q[1], q[2], i + 1, k), (q[2], q[3], i, k + 1),
                                   (q[3], q[0], i - 1, k)):
                if not inc(ni, nk):
                    mid = (outer[ta].co + outer[tb].co) / 2
                    face([outer[ta], outer[tb], inner[tb], inner[ta]], mid - cen, wall_pal)
    return _piece(bm, pals, name, outline, smooth)


def _surface_loop(c, z, lift, n=48):
    """Points around the leg at height z, lifted off the real surface."""
    pts = []
    for k in range(n):
        p, nn = c.surface(TAU * k / n, z)
        pts.append(p + nn * lift)
    return pts


# ------------------------------------------------------------------ body access (Compressio pinch)
def _body_mesh(c):
    """The body mesh body_pieces() just built (not yet merged): matched by vertex positions."""
    n = len(c._verts)
    for me in bpy.data.meshes:
        if me.users == 0 and me.name.startswith("sockbody") and len(me.vertices) == n:
            if all((me.vertices[i].co - c._verts[i]).length < 1e-5 for i in (0, n // 2, n - 1)):
                return me
    return None


def _deform_body(c, fn):
    """Moves every body vertex with fn(co, normal) -> co and re-syncs c's ray-cast surface, so later
    c.surface / c.ray calls see the deformed body. Returns False if the body mesh was not found."""
    me = _body_mesh(c)
    if me is None:
        return False
    me.update()
    normals = [v.normal.copy() for v in me.vertices]
    for v, n in zip(me.vertices, normals):
        v.co = fn(v.co.copy(), n)
    me.update()
    verts = [v.co.copy() for v in me.vertices]
    c._verts = verts
    c._bvh = BVHTree.FromPolygons(verts, c._polys)
    c._vnormals = [v.normal.copy() for v in me.vertices]
    return True


# ------------------------------------------------------------------ Knee-High Kevin
def feat_kneehigh(c):
    """The tall leg and the three white stripes are the body itself (SPEC_OVERRIDES)."""
    return []


# ------------------------------------------------------------------ Slipperino Grippolini
def _fluff_roll(c, pal, Rc, zc, rh, rv, lumps=13, n_a=65, name="fluff"):
    """A fleecy roll round the rim: an elliptical cross-section (rh across, rv up) whose outer and
    top side swell into `lumps` soft puffs of uneven size and spacing (each puff gets its own
    width and height from a fixed pseudo-random table) plus a small vertical wobble, while the
    inner half stays smooth and constant - so the roll always covers the sock's lip. The puffs are
    shallow (valleys ~0.18 of the roll radius) so the roll's own ink hull follows the silhouette
    and never shows as loose loops across the white."""
    bs = [math.radians(x) for x in (-90, -50, -15, 15, 45, 75, 105, 140, 185, 235)]
    amp = [0.6 + 0.4 * ((k * 0.618034 + 0.31) % 1.0) for k in range(lumps)]   # per-puff height

    def w(b):                     # 1 on the outer / top side, 0 on the inner half and underneath
        return _smooth((math.cos(b - 0.35) + 0.15) / 0.6)

    def lump_t(a):                # warped lump coordinate: puffs of uneven width / spacing
        return lumps * a / TAU + 0.22 * math.sin(3 * a + 0.7) + 0.12 * math.sin(5 * a + 2.1)

    bm = bmesh.new()
    rows = []
    for k in range(n_a):
        a = TAU * k / n_a
        t = lump_t(a)
        i0 = math.floor(t + 0.5)
        f = t - i0                                   # -0.5..0.5 inside puff i0
        l1 = math.cos(math.pi * f) ** 0.7            # 1 at the puff's centre, 0 at the valleys
        dep = 0.18 - 0.18 * amp[i0 % lumps] * l1     # inward dent: 0.18 at the valleys
        wob = 0.02 * math.sin(4 * a + 1.0) + 0.01 * amp[i0 % lumps] * l1
        row = []
        for b in bs:
            m = 1.0 - w(b) * dep
            r = Rc + rh * math.cos(b) * m
            row.append(bm.verts.new((math.cos(a) * r, math.sin(a) * r, zc + rv * math.sin(b) * m + wob)))
        rows.append(row)
    nb = len(bs)
    for k in range(n_a):
        k2 = (k + 1) % n_a
        for j in range(nb):
            j2 = (j + 1) % nb
            bm.faces.new((rows[k][j], rows[k2][j], rows[k2][j2], rows[k][j2]))
    bm.normal_update()
    bm.faces.ensure_lookup_table()
    f0 = bm.faces[0]
    cen = f0.calc_center_median()
    if f0.normal.dot(cen - Vector((cen.x, cen.y, 0.0)).normalized() * Rc - Vector((0.0, 0.0, zc))) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    return _piece(bm, pal, name)


def _grip_dot(c, p, nn, along, rd, pal, ink, squash=0.28, seg=14, rim=0.03, name="grip"):
    """A flat rubber grip dot: a low white dome (rd across, rd * squash tall) whose base ring is
    projected onto the real surface, inside an even ink rim (an annulus rd .. rd + rim, also on the
    surface, centred under the dome) - one small mesh with no hull of its own."""
    t1 = (Vector(along) - nn * Vector(along).dot(nn)).normalized()
    t2 = nn.cross(t1)
    bm = bmesh.new()
    pals = []

    def on_surf(rr, ph, lift):
        q = p + (t1 * math.cos(ph) + t2 * math.sin(ph)) * rr
        hit = c.ray(q + nn * 0.3, -nn)
        return (hit[0] + nn * lift) if hit else (q + nn * lift)

    phs = [TAU * j / seg for j in range(seg)]
    outer = [bm.verts.new(on_surf(rd + rim, ph, 0.01)) for ph in phs]
    base = [bm.verts.new(on_surf(rd * 0.98, ph, 0.012)) for ph in phs]
    mid = [bm.verts.new(on_surf(rd * 0.68, ph, 0.012 + rd * squash * 0.72)) for ph in phs]
    top = bm.verts.new(p + nn * (0.012 + rd * squash))

    def face(vs, pal_):
        f = bm.faces.new(vs)
        f.normal_update()
        if f.normal.dot(nn) < 0:
            f.normal_flip()
        pals.append(pal_)

    for j in range(seg):
        j2 = (j + 1) % seg
        face((outer[j], outer[j2], base[j2], base[j]), ink)
        face((base[j], base[j2], mid[j2], mid[j]), pal)
        face((mid[j], mid[j2], top), pal)
    pc = _piece(bm, pals, name, outline=False)
    pc.flat_faces = [i for i, q in enumerate(pals) if q == ink]
    return [pc]


def feat_slipperino(c):
    """A fleecy rolled cuff (a lumpy off-white roll over the rim) and white rubber grip dots in thin
    ink rings on the sole that run up both sides of the foot, so a dotted band shows above the
    sole line from the side and the 3/4 view, and the whole underside is dotted from below."""
    tid, h = c.tid, c.h
    fluff = hexcol(f"{tid}_fluff", "#F3F6FF")
    dot = hexcol(f"{tid}_grip", "#F7F9FF")
    out = [_fluff_roll(c, fluff, c.top_r + 0.03, h - 0.07, 0.25, 0.22)]
    # grip dots: a staggered grid (~1.6 dot diameters apart) cast from a core line inside the foot
    # (heel -> toe) out to the underside and up both sides, so a dotted band shows above the sole
    # line from the side and the 3/4 view and the whole underside is dotted from below
    rd = 0.105
    h0, t0 = Vector(c.heel_c), Vector(c.toe_c)
    ax = t0 - h0
    ln = ax.length
    down = Vector((-ax.z, 0.0, ax.x)) if ax.x < 0 else Vector((ax.z, 0.0, -ax.x))
    down.normalize()
    step = rd * 2 * 1.6 / ln                         # along the foot, as a fraction of heel -> toe
    rows = (-80, -57, -34, -11, 11, 34, 57, 80)
    for r_i, phi in enumerate(rows):
        ph = math.radians(phi)
        dv = down * math.cos(ph) + Y * math.sin(ph)
        s_ = -0.16 + (step / 2 if r_i % 2 else 0.0)
        while s_ < 1.2:
            hit = c.ray(h0 + ax * s_, dv)
            s_ += step
            if hit is None or hit[1].dot(dv) < 0.35:
                continue
            out += _grip_dot(c, hit[0], hit[1], ax, rd, dot, K.BLACK)
    return out


# ------------------------------------------------------------------ Compressio Stressio
def feat_compressio(c):
    """The body is squeezed in at three red elastic bands: two round the leg under the face (the
    spec's stripes cut their borders; here those loops are pulled toward the leg axis) and one
    round the middle of the foot (pulled toward the foot axis), each with a red band sitting in
    its groove; the leg's outline eases smoothly in and out of each pinch (a soft roll of fabric
    between the two leg bands, a low puff above them). Plus a worried open mouth with clenched
    teeth, a big sweat drop on the heel-side temple and a small one on the far temple."""
    tid, d = c.tid, c.d
    dd = d if d else 1.0
    red = c.accent
    spec = c.spec
    leg_bands = sorted((z0, z1) for z0, z1, _col in spec.get("stripes", []))
    pinch = 0.15
    # the foot band: a plane across the foot axis just behind where the toe patch starts (on the side)
    fd = Vector(c.foot_dir)
    al = c.foot_alpha
    upf = Vector((dd * math.sin(al), 0.0, math.cos(al)))
    a0 = Vector(c.foot_axis[0])
    tlen = (c.toe_tip - a0).length
    t_side = tlen * 0.6
    for k in range(80):
        t = tlen * k / 80
        hit = c.ray(a0 + fd * t, (0.0, -1.0, 0.0))
        if hit and c.in_toe(hit[0]):
            t_side = t
            break
    t_b = t_side - 0.2
    fb_h, fb_fall, fb_pinch = 0.05, 0.25, 0.2
    # the leg's radial offset as a smooth curve through key heights (cosine easing between them:
    # zero slope at every key, so the pinches and puffs are round, never pointed ridges): nothing
    # down at the instep, pulled in by `pinch` under each band, only half let out between two
    # bands (a soft roll of squeezed fabric), and one low round puff above the top band
    keys = [(c.instep_z, 0.0)]
    for k, (z0, z1) in enumerate(leg_bands):
        if k:
            gz = (leg_bands[k - 1][1] + z0) / 2
            keys.append((gz, -pinch * 0.15))
        keys += [(z0, -pinch), (z1, -pinch)]
    if leg_bands:
        ztop = leg_bands[-1][1]
        keys += [(ztop + 0.24, 0.03), (ztop + 0.46, 0.0)]

    def leg_offset(z):
        """Radial change of the leg at height z (see keys above)."""
        if not leg_bands or z <= keys[0][0] or z >= keys[-1][0]:
            return 0.0
        for (za, va), (zb_, vb) in zip(keys, keys[1:]):
            if za <= z <= zb_:
                t = (z - za) / max(zb_ - za, 1e-6)
                return va + (vb - va) * (1.0 - math.cos(math.pi * t)) / 2
        return 0.0

    def squeeze(co, n):
        r = math.hypot(co.x, co.y)
        if co.z > c.instep_z - 0.02 and r > 1e-4:
            k = (r + leg_offset(co.z)) / r
            co = Vector((co.x * k, co.y * k, co.z))
        if co.z < c.instep_z and d:
            q = co - a0
            t = q.dot(fd)
            rv = q - fd * t
            dist = max(abs(t - t_b) - fb_h, 0.0)
            if dist < fb_fall and 0.2 < rv.length < 1.0:
                wgt = _smooth(1.0 - dist / fb_fall)
                co = co - rv.normalized() * (fb_pinch * wgt)
        return co

    _deform_body(c, squeeze)
    out = []
    # a red elastic band in each groove
    for z0, z1 in leg_bands:
        zc = (z0 + z1) / 2
        pts = _surface_loop(c, zc, 0.02, 48)
        out.append(_sweep(pts, [0.075] * len(pts), red, seg=10, flat=((z1 - z0) / 2 + 0.035) / 0.075, up=Z,
                          fixed_up=True, closed=True, samples=1, name="band"))
    if d:
        pts = []
        for k in range(40):
            ph = TAU * k / 40
            hit = c.ray(a0 + fd * t_b, upf * math.cos(ph) + Y * math.sin(ph))
            if hit:
                pts.append(hit[0] + hit[1] * 0.02)
        out.append(_sweep(pts, [0.075] * len(pts), red, seg=10, flat=(fb_h + 0.06) / 0.075, up=fd,
                          fixed_up=True, closed=True, samples=1, name="footband"))
    # worried open mouth: a frowning oval, dark inside, a strip of clenched teeth along the top
    fp = c.face_point
    my = c.mouth_z + 0.02
    mw = 0.24

    def mouth(g):
        ww = mw + g

        def q(u):
            return min(abs(u) / ww, 1.0)

        def cen(u):
            return my - 0.08 * q(u) ** 2

        def half(u):
            return (0.1 + g) * max(1.0 - q(u) ** 2.4, 0.0) ** 0.55

        return -ww, ww, (lambda u: cen(u) + half(u) * 0.85), (lambda u: cen(u) - half(u))

    out += S._inked(fp, mouth, C_PINKMOUTH, border=0.035, lift=0.026, n=13, name="mouth")
    tw = mw * 0.72

    def teeth(g):
        _x0, _x1, top, _bot = mouth(0.0)
        return (-tw, tw, (lambda u: top(u) + 0.004), (lambda u: top(u) - 0.05))

    out += [S._inked(fp, teeth, K.WHITE, border=0.0, lift=0.04, n=9, name="teeth")[1]]
    # sweat drops: teardrops lying on the temples
    sweat = hexcol(f"{tid}_sweat", "#8FD6FF")
    # the big drop on the heel-side temple, its base at the eye tops and its tip well under the
    # cuff seam; a small one lower on the far temple
    sc0 = 0.88
    z_big = min(c.ey + c.eye_r * 0.45, c.cuff_z - 0.1 - 0.27 * sc0)
    for ang, z, sc in ((-dd * 1.1, z_big, sc0), (dd * 1.3, c.ey - 0.2, 0.74)):
        p, n = c.surface(ang, z)
        upv = (Z - n * Z.dot(n)).normalized()
        base = p + n * (0.07 * sc)
        out.append(_sweep([base, base + upv * (0.12 * sc), base + upv * (0.25 * sc) - n * (0.02 * sc)],
                          [0.105 * sc, 0.075 * sc, 0.012], sweat, seg=10, samples=4, cap0=1.0, cap1=0.5,
                          flat=0.62, up=n, name="sweat"))
    return out


# ------------------------------------------------------------------ Sockhopper
def _plank(ctr, hx, hy, th, bevel, pal_top, pal_side, rc=0.05, ck=4, name="plank"):
    """A crisp horizontal plank: a rounded-corner rectangle (half sizes hx, hy, corner radius rc)
    th thick with vertical side / end faces and a small rounded `bevel` on the top and bottom
    edges. Top faces pal_top, the rest pal_side."""
    outl = []
    for cx, cy, a0 in ((1, 1, 0.0), (-1, 1, 0.5), (-1, -1, 1.0), (1, -1, 1.5)):
        for q in range(ck + 1):
            a = (a0 + 0.5 * q / ck) * math.pi
            outl.append((cx * (hx - rc) + rc * math.cos(a), cy * (hy - rc) + rc * math.sin(a)))
    b = bevel
    prof = [(None, -th / 2), (b, -th / 2), (b * 0.29, -th / 2 + b * 0.29), (0.0, -th / 2 + b), (0.0, th / 2 - b),
            (b * 0.29, th / 2 - b * 0.29), (b, th / 2), (None, th / 2)]
    bm = bmesh.new()
    rows = []
    for ins, z in prof:
        if ins is None:
            rows.append(bm.verts.new(ctr + Vector((0.0, 0.0, z))))
            continue
        row = []
        sx, sy = (hx - ins) / hx, (hy - ins) / hy      # inset toward the centre
        for ox, oy in outl:
            row.append(bm.verts.new(ctr + Vector((ox * sx, oy * sy, z))))
        rows.append(row)
    n = len(outl)
    for k in range(len(rows) - 1):
        A, B = rows[k], rows[k + 1]
        for j in range(n):
            j2 = (j + 1) % n
            if isinstance(A, list) and isinstance(B, list):
                vs = (A[j], A[j2], B[j2], B[j])
            elif isinstance(A, list):
                vs = (A[j], A[j2], B)
            else:
                vs = (A, B[j2], B[j])
            bm.faces.new(vs)
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    for f in bm.faces:
        f.normal_update()
    pals = [pal_top if f.normal.z > 0.5 else pal_side for f in bm.faces]
    return _piece(bm, pals, name, True, True)


def feat_sockhopper(c):
    """The sheet's red pogo stick in front of the sock: a black-gripped handlebar with a short steel
    sleeve in the middle just under the eyes, the red pole down to a long narrow red bar centred on
    it under the front edge of the foot (the toe rests on its back edge), then a steel shaft and a
    chunky flat-bottomed black rubber tip below the floor."""
    tid, d = c.tid, (c.d if c.d else 1.0)
    red = hexcol(f"{tid}_pogo", "#EC3030")
    red_top = hexcol(f"{tid}_pogo_top", "#F5473F")
    red_d = hexcol(f"{tid}_pogo_dark", "#AE1D1D")
    grip = hexcol(f"{tid}_grip", "#46454A")
    steel = hexcol(f"{tid}_steel", "#B4B6BA")
    rubber = hexcol(f"{tid}_rubber", "#3E3D42")
    pr = 0.075
    px = d * 0.12
    z_bar = c.ey - c.eye_rim_r - 0.47
    zs = [0.45 + (z_bar - 0.45) * i / 12 for i in range(13)]
    fy = min(c.front(px, z)[1] for z in zs)
    py = fy - pr - 0.05
    # the plank: a long narrow bar centred on the pole (about as long as the handlebar, its depth
    # under a third of its length), lying under the front edge of the foot: its top is the lowest
    # point of the sole along its back edge, so the toe rests on / drapes over that edge
    hb, gr = 0.64, 0.115
    bhx = hb + gr * 0.55                  # half length = the handlebar's, grip caps included
    by0, by1 = py - 0.2, py + 0.28
    low = 9.0
    for i in range(25):
        s = c.sole(px + bhx * (2 * i / 24 - 1), by1)
        if s is not None:
            low = min(low, s[0].z)
    peg_th = 0.15
    peg_top = (low if low < 5.0 else c.sole_z + 0.1) + 0.008
    out = []
    # pole (red) from the plank up into the sleeve
    out.append(_sweep([(px, py, peg_top - peg_th * 0.5), (px, py, z_bar - 0.06)], [pr, pr], red, seg=12,
                      samples=1, cap0=0, cap1=0, name="pole"))
    # handlebar: black grips with rounded ends, a short steel sleeve as wide as them in the middle
    out.append(_sweep([(px - hb, py, z_bar), (px + hb, py, z_bar)], [gr, gr], grip, seg=12, samples=1,
                      cap0=0.55, cap1=0.55, name="handlebar"))
    out.append(_sweep([(px - 0.15, py, z_bar), (px + 0.15, py, z_bar)], [gr + 0.012, gr + 0.012], steel, seg=12,
                      samples=1, cap0=0, cap1=0, name="sleeve"))
    # the plank: lighter red top, darker red front / back / ends
    out.append(_plank(Vector((px, (by0 + by1) / 2, peg_top - peg_th / 2)), bhx, (by1 - by0) / 2, peg_th, 0.03,
                      red_top, red_d, name="plank"))
    # steel shaft, then a chunky black rubber tip: ~2.5x the shaft wide, about as tall as it is
    # wide, a flat bottom with a small rounded bevel
    z_sh = peg_top - peg_th
    out.append(_sweep([(px, py, z_sh + 0.02), (px, py, z_sh - 0.47)], [0.08, 0.08], steel, seg=10, samples=1,
                      cap0=0, cap1=0, name="shaft"))
    t1, t0 = z_sh - 0.44, z_sh - 0.81      # top, bottom of the tip
    prof = [(0.0, t0), (0.13, t0), (0.158, t0 + 0.006), (0.174, t0 + 0.024), (0.18, t0 + 0.05),
            (0.196, t1 - 0.05), (0.2, t1 - 0.022), (0.19, t1 - 0.004), (0.165, t1), (0.0, t1)]
    out.append(_lathe(prof, rubber, seg=18, mat=Matrix.Translation((px, py, 0.0)), name="tip"))
    # (the pogo reaches t0 ~0.8 under the floor: a standing Sockhopper wants its _Base there)
    c.base_z = t0
    return out


# ------------------------------------------------------------------ DJ Dryer Sheet
def feat_djdryer(c):
    """Big padded headphones (chunky magenta cups turned a little toward the front on a flat dark
    band swept back over the top of the head), dark DJ shades over the googly eyes, and a dryer
    sheet tied round the neck: a white sheet with a faint lavender dot print draping down the
    back like a little cape, flaring out toward a wavy hem whose corners peek out at the sides."""
    tid, h, d = c.tid, c.h, c.d
    dd = d if d else 1.0
    mag = hexcol(f"{tid}_cup", "#E040B8")
    mag_l = hexcol(f"{tid}_cup_light", "#F59BDD")
    dark = hexcol(f"{tid}_band", "#2E2840")
    lens = hexcol(f"{tid}_lens", "#262236")
    sheet = hexcol(f"{tid}_sheet", "#FBFBFF")
    dots = hexcol(f"{tid}_sheet_dot", "#D5CCF4")
    out = []
    # headphones: chunky cups on the sides of the head, faces turned 15 deg toward the front
    z_cup = c.ey + 0.14
    yaw = math.radians(15.0)
    cup_c, cup_n = [], []
    for s_ in (-1, 1):
        p, n = c.surface(s_ * math.radians(84.0), z_cup)
        n = Vector((s_ * math.cos(yaw), -math.sin(yaw), 0.0))
        out.append(_puck(p + n * 0.08, n, Z, 0.36, 0.38, 0.18, dark, p=2.0, bevel=0.35, seg=24, rings=2,
                         name="cushion"))
        out.append(_puck(p + n * 0.3, n, Z, 0.42, 0.44, 0.32, mag, p=2.0, bevel=0.3, bulge=0.03, seg=30,
                         name="cup"))
        out.append(_puck(p + n * 0.475, n, Z, 0.2, 0.21, 0.05, mag_l, p=2.0, bevel=0.4, seg=16, rings=2,
                         outline=False, name="cupcap"))
        cup_c.append(p + n * 0.3)
        cup_n.append(n)
    # the band: a flat padded strap rising out of the inner tops of the cups, hugging the sides of
    # the head and arching low over the rim - swept back as it rises (headphones pushed back on the
    # head), so over the top its front edge is ~0.47 behind the leg axis: clear of the clothespin
    # the game clips on the axis (y -0.35..0.46) when the sock hangs on the line
    yb = (cup_c[0].y + cup_c[1].y) / 2
    zc = cup_c[0].z
    xs = c.top_r + 0.1
    zt = zc + 0.3
    y_top = 0.62
    band = [(-xs - 0.04, zt), (-xs, h - 0.08), (-xs * 0.92, h + 0.2), (-xs * 0.52, h + 0.36), (0.0, h + 0.39),
            (xs * 0.52, h + 0.36), (xs * 0.92, h + 0.2), (xs, h - 0.08), (xs + 0.04, zt)]
    band = [(x, _lerp(yb, y_top, _smooth(min((z - zc) / (h + 0.25 - zc), 1.0))), z) for x, z in band]
    out.append(_sweep(band, [0.15] * len(band), dark, seg=12, samples=5, cap0=0.0, cap1=0.0, flat=0.45,
                      up=Vector((-1.0, 0.0, 0.0)), name="headband"))
    # shades over the eyes; short straight arms run back from the lens tops into the cups
    lens_c = []
    for i, ec in enumerate(c.eyes):
        en = c.eye_n[i]
        ctr = Vector(ec) + en * (c.eye_r * c.eye_flat + 0.07)
        side = -1 if i == 0 else 1
        out.append(_puck(ctr + Vector((side * 0.015, 0.0, -0.02)), en, Z, 0.31, 0.25, 0.08, lens, p=3.4,
                         bevel=0.25, bulge=0.025, seg=20, name="lens"))
        gl = ctr + Vector((side * 0.015 - 0.1, 0.0, 0.07)) + en * 0.075
        out.append(_puck(gl, en, Vector((0.6, 0.0, 1.0)), 0.035, 0.11, 0.02, K.WHITE, p=2.0, bevel=0.4, seg=10,
                         rings=2, outline=False, name="glint"))
        lens_c.append(ctr)
    a_, b_ = lens_c
    mid = (a_ + b_) / 2 + Vector((0.0, -0.02, 0.1))
    out.append(_sweep([a_ + Vector((0.2, 0.0, 0.1)), mid, b_ + Vector((-0.2, 0.0, 0.1))], [0.04] * 3, lens,
                      seg=8, samples=4, cap0=0, cap1=0, name="bridge"))
    for i, (lc, cc) in enumerate(zip(lens_c, cup_c)):
        side = -1 if i == 0 else 1
        za = lc.z + 0.13
        p0 = Vector((lc.x + side * 0.27, lc.y + 0.02, za))
        p1 = Vector((cc.x, cc.y, za))
        out.append(_sweep([p0, p1], [0.05, 0.05], lens, seg=8, samples=1, cap0=0.8, cap1=0, name="arm"))
    # dryer sheet: tied round the neck - a thin tie, a small knot under the chin with two short
    # square-cornered ends ...
    z_top = c.mouth_z - 0.2
    z_bot = z_top - 0.15

    def tie(u, v):
        a = TAU * u
        return a, _lerp(z_top, z_bot + 0.02 * math.sin(5 * a), v), 0.03

    out.append(_shell(c, 36, 1, tie, 0.045, sheet, wrap=True, name="tie"))
    ka = dd * 0.22
    kp, kn = c.surface(ka, (z_top + z_bot) / 2)
    out.append(_puck(kp + kn * 0.1, kn, Z, 0.12, 0.1, 0.11, sheet, p=2.2, bevel=0.4, seg=14, rings=2, name="knot"))
    for a0, spread, ln in ((ka - dd * 0.13, -dd * 0.12, 0.36), (ka + dd * 0.13, dd * 0.16, 0.3)):
        def end(u, v, a0=a0, spread=spread, ln=ln):
            a = a0 + (u - 0.5) * 0.3 + spread * v
            return a, _lerp(z_bot + 0.03, z_bot - ln, v) - 0.03 * (u - 0.5) * v, 0.07 + 0.04 * v

        out.append(_shell(c, 3, 3, end, 0.035, sheet, name="tieend"))
    # ... and the sheet itself hanging down the back like a little cape: gathered at the tie, it
    # drapes away from the leg toward a wider, gently wavy hem (three soft vertical folds), its two
    # bottom corners flaring out past the leg so they peek out of the front silhouette; a faint
    # lavender dot print
    z_cape0, z_cape1 = z_top - 0.04, c.instep_z - 0.06
    rcap = c.RL * 1.1

    def csurf(a, z):
        """The leg under the sheet; where a ray would run into the instep / heel, a plain
        cylinder instead (the sheet hangs straight past them)."""
        dvec = Vector((math.sin(a), -math.cos(a), 0.0))
        p, n = c.surface(a, z)
        if math.hypot(p.x, p.y) > rcap:
            return dvec * rcap + Z * z, dvec
        return p, (n + dvec).normalized()

    def cape_at(u, v):
        half = 0.74 + 0.42 * v ** 1.4
        a = math.pi + (u - 0.5) * 2 * half
        fold = 0.5 - 0.5 * math.cos(TAU * 3 * u)       # 1 on the three ridges, 0 between
        hem = (0.045 * fold - 0.02) * v ** 3 + 0.02 * math.sin(TAU * 1.5 * u + 0.6) * v ** 3
        lift = 0.05 + 0.3 * v ** 1.6 + 0.07 * fold * v ** 1.2
        return a, _lerp(z_cape0, z_cape1, v) - hem, lift

    th = 0.05
    out.append(_shell(c, 18, 8, cape_at, th, sheet, surf=csurf, name="cape"))

    def cape_pt(u, v):
        a, z, lift = cape_at(u, v)
        p, n = csurf(a, z)
        return p + n * (lift + th)

    for k, (u, v) in enumerate([(0.17, 0.2), (0.5, 0.2), (0.83, 0.2), (0.33, 0.44), (0.67, 0.44),
                                (0.12, 0.66), (0.5, 0.66), (0.88, 0.66), (0.3, 0.88), (0.7, 0.88)]):
        q = cape_pt(u, v)
        du = cape_pt(u + 0.01, v) - cape_pt(u - 0.01, v)
        dv = cape_pt(u, v + 0.01) - cape_pt(u, v - 0.01)
        n = du.cross(dv).normalized()
        if n.dot(Vector((q.x, q.y, 0.0))) < 0:
            n = -n
        out.append(_puck(q + n * 0.012, n, Z, 0.055, 0.055, 0.012, dots, p=2.0, bevel=0.3, seg=10, rings=1,
                         outline=False, name="sheetdot"))
    return out


# ------------------------------------------------------------------ Socktopus
def _tentacle(c, q1, u1, fdir, r_leg, r_toe, Rb, foot_len, bump, name="tentacle"):
    """One Socktopus tentacle as a little sock: a straight leg from q1 (just inside the sack)
    along u1, a soft heel bend of radius Rb into the horizontal foot direction fdir, a foot with a
    visible instep that swells into a fat round toe (bottom on the floor). The heel corner bulges
    out by `bump`; the dark heel patch and toe cap are cut in as clean curves. The leg itself is
    body colour right up to the sack (like the sheet)."""
    zf = r_toe                                          # foot axis height: the toe bottom on the floor
    nb = (fdir - u1 * fdir.dot(u1)).normalized()
    thm = math.acos(max(-1.0, min(1.0, u1.dot(fdir))))
    drop = Rb * (nb.z * (1 - math.cos(thm)) + u1.z * math.sin(thm))
    q0 = q1 - u1 * 0.22
    tA = (zf - drop - q1.z) / u1.z                      # leg length so the foot lands at height zf
    A = q1 + u1 * tA
    cb = A + nb * Rb
    P, R = [], []
    nl = max(2, math.ceil((tA + 0.22) / 0.16))
    for k in range(nl):
        P.append(q0.lerp(A, k / nl))
        R.append(r_leg)
    nbend = 10
    for k in range(nbend + 1):
        th = thm * k / nbend
        P.append(cb + (-nb * math.cos(th) + u1 * math.sin(th)) * Rb)
        R.append(r_leg * (1.0 + 0.02 * _smooth(k / nbend)))
    Bp = P[-1]
    nf = 6
    r_b = r_leg * 1.02
    for k in range(1, nf + 1):
        f = k / nf
        P.append(Bp + fdir * (foot_len * f))
        # the instep stays leg-thick for the first part of the foot, then eases into the toe
        R.append(_lerp(r_b, r_toe, _smooth(max(f - 0.25, 0.0) / 0.75)))
    bm, info = _tube_bm(P, R, seg=16, up=Z, cap0=None, cap1=1.0, cap_rings=4)
    # the heel corner: push the outside of the bend out (a little sock's heel, not an elbow)
    m = (-nb * math.cos(thm / 2) + u1 * math.sin(thm / 2)).normalized()
    pmid = cb + m * Rb
    for v in bm.verts:
        ctr, e = info[v]
        w = max(e.dot(m), 0.0) ** 2 * math.exp(-((ctr - pmid).length / 0.24) ** 2)
        v.co = v.co + e * (bump * w)
    heel_pt = cb + m * (Rb + r_leg * 1.015 + bump)
    toe_end = P[-1] + fdir * r_toe
    # the heel patch: an ellipsoid round the heel corner, wide across the foot so it wraps round
    # both sides of the heel (seen from the side it is a round patch, like the sheet)
    lat = fdir.cross(Z).normalized()
    hw = m.cross(lat).normalized()

    def heel_fn(p):
        q = p - heel_pt
        return math.sqrt((q.dot(m) / 0.3) ** 2 + (q.dot(lat) / 0.4) ** 2 + (q.dot(hw) / 0.27) ** 2) - 1.0

    regions = [(heel_fn, c.body_dark),
               (lambda p: (p - (toe_end + fdir * 0.06)).length - 0.36, c.body_dark)]
    return _cut_colour(bm, regions, c.body, name)


def feat_socktopus(c):
    """Six chunky tentacles hanging from the sack's bottom - each one a little sock of its own like
    the sheet: a body-coloured leg going down, a heel corner, a foot turning outward into a fat
    toe, darker heel and toe patches (the sheet's dark patch where the tentacles start is the
    sack's own big front patch, drawn by the body). The two front feet both turn to the viewer's
    left (the sheet's two middle feet), the side ones point straight out left and right, the back
    ones out behind."""
    O, R0 = c.bottom_ring
    out = []
    r_leg = 0.215
    # roots round the sack's bottom (0 = face, -Y): the front pair at +-30 deg, the sides at +-90,
    # the back pair at +-162 deg - close behind the middle, so from the front they fill the gap
    # between the two front legs (all six read, like the sheet)
    roots = (30.0, 90.0, 162.0, -162.0, -90.0, -30.0)
    feet = {0: Vector((-0.84, -0.54, 0.0)), 5: Vector((-0.84, -0.54, 0.0))}   # front pair turn left
    for i, deg in enumerate(roots):
        a = math.radians(deg)
        rad = Vector((math.sin(a), -math.cos(a), 0.0))
        fdir = feet.get(i, rad).normalized()
        splay = {0: 0.22, 5: 0.22, 1: 0.44, 4: 0.44}.get(i, 0.36)   # the side legs splay out the most
        u1 = (rad * splay - Z).normalized()             # the leg: straight, splayed outward
        q1 = Vector((O.x, O.y, O.z - 0.1)) + rad * (R0 * 0.7)    # where it leaves the sack
        out.append(_tentacle(c, q1, u1, fdir, r_leg, r_leg * 1.16, 0.35, 0.3, 0.08))
    # the sack's underside: a thin dark disc hugging it inside the bottom rim
    bm = bmesh.new()
    na, fr = 24, (0.3, 0.55, 0.78, 0.96)
    ctr_v = bm.verts.new(c.bottom_point(0.0, 0.0, 0.012)[0])
    rings = [[bm.verts.new(c.bottom_point(TAU * j / na, f, 0.012)[0]) for j in range(na)] for f in fr]
    for j in range(na):
        bm.faces.new((ctr_v, rings[0][(j + 1) % na], rings[0][j]))
    for ra, rb in zip(rings, rings[1:]):
        for j in range(na):
            j2 = (j + 1) % na
            bm.faces.new((ra[j], ra[j2], rb[j2], rb[j]))
    bm.normal_update()
    if sum(f.normal.z for f in bm.faces) > 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    out.append(_piece(bm, c.body_dark, "underside", outline=False))
    return out


# ------------------------------------------------------------------ Sir Sockington III
def feat_sockington(c):
    """A knight: a silver great helm over the top of the sock - the googly eyes peer out of a visor
    slit that dips toward the middle like a determined frown, a gold cross (brow band and a nasal
    bar down between the eyes) on its face, a low domed top with a red plume sweeping back -
    and a tall shield-shaped breastplate from just under the helm down over the ankle, with gold
    trim, a red diamond emblem on the chest bulge and a leather strap round the back."""
    tid, h = c.tid, c.h
    steel = hexcol(f"{tid}_steel", "#B8C0CC")
    steel_d = hexcol(f"{tid}_steel_dark", "#7F8898")
    visor_in = hexcol(f"{tid}_visor_in", "#3E4250")
    plume = hexcol(f"{tid}_plume", "#E04444")
    plume_d = hexcol(f"{tid}_plume_dark", "#B8302F")
    strap = hexcol(f"{tid}_strap", "#6E4A2E")
    gold, gold_d = C_GOLD, C_GOLD2
    out = []
    ey, rim = c.ey, c.eye_rim_r
    Rh = c.top_r + 0.11                 # inner radius of the helm's wall (clears the eyeballs)
    th = 0.07
    z_b = ey - rim - 0.12               # lower rim of the helm: just under the visor slit
    z_t = h + 0.06                      # top of the wall (the dome sits on it)
    a_s = 0.98                          # half angle of the visor slit

    def slot(a):
        """(bottom, top) of the slit: it shows the middle of the eyes (pupils look down), its top
        edge slopes down toward the middle like a frown, the ends taper."""
        t = min(abs(a) / a_s, 1.0)
        taper = max(math.sqrt(max(1.0 - t ** 5, 0.0)), 0.18)
        mid = ey - 0.07 + 0.05 * t
        return mid - 0.19 * taper, mid + (0.1 + 0.1 * t) * taper

    def flare(z):                       # a straight wall: the rim trim sits flush (no ghost ink)
        return 0.0

    n_f, n_b = 14, 14
    nu = n_f + n_b

    def ang(i):
        i %= nu
        if i <= n_f:
            return -a_s + 2 * a_s * i / n_f
        return a_s + (TAU - 2 * a_s) * (i - n_f) / n_b

    def helm(u, v):
        a = ang(round(u * nu))
        sb, st = slot(a)
        rows = [z_b, (z_b + sb) / 2, sb, (sb + st) / 2, st, (st + z_t) / 2, z_t]
        return a, rows[round(v * 6)], 0.0

    def hsurf(a, z):
        nn = Vector((math.sin(a), -math.cos(a), 0.0))
        return nn * (Rh + flare(z)) + Z * z, nn

    out.append(_shell(c, nu, 6, helm, th, steel, wrap=True, surf=hsurf, wall_pal=visor_in,
                      hole=lambda i, k: i < n_f and k in (2, 3), name="helm"))
    Ro = Rh + th
    top = z_t + 0.45                    # a low dome: the whole knight stays about KneeHigh's height
    out.append(_lathe([(0.0, z_t - 0.15), (Rh, z_t - 0.02), (Ro, z_t), (Ro - 0.01, z_t + 0.11), (Ro * 0.9, z_t + 0.25),
                       (Ro * 0.66, z_t + 0.36), (Ro * 0.34, top - 0.025), (0.0, top)], steel, seg=nu, name="dome"))
    # gold trims round the rim and where the dome meets the wall: half sunk in the steel with no
    # hull of their own (a torus hull against a wall leaves a detached ink line beside it), inside
    # the helm's own ink at the silhouette
    for zz, rr, rt, ol in ((z_b + 0.045, Ro + flare(z_b), 0.055, False), (z_t, Ro, 0.05, False)):
        out.append(_sweep([(math.cos(TAU * k / 30) * rr, math.sin(TAU * k / 30) * rr, zz) for k in range(30)],
                          [rt] * 30, gold, seg=6, up=Z, fixed_up=True, closed=True, samples=1, outline=ol,
                          name="helmtrim"))
    # gold cross on the face: a brow band over the slit and a nasal bar from it down across the
    # slit (between the eyes) to the lower trim, standing 0.04
    # proud of the helm with darker gold edges (no outline hull: the helm's ink frames them)
    def brow(u, v):
        a = (u - 0.5) * 2 * (a_s + 0.05)
        _sb, st = slot(a)
        z = st + 0.04
        return a, _lerp(z + 0.1, z, v), th + 0.004

    out.append(_shell(c, 12, 1, brow, 0.04, gold, surf=hsurf, wall_pal=gold_d, outline=False, name="browband"))

    def nose(u, v):
        a = (u - 0.5) * 0.12 / Ro
        return a, _lerp(slot(0.0)[1] + 0.06, z_b + 0.07, v), th + 0.004

    out.append(_shell(c, 2, 4, nose, 0.04, gold, surf=hsurf, wall_pal=gold_d, outline=False, name="nasal"))
    # plume: one tall red tuft sweeping back (a tall centre feather, two shorter ones tight beside it)
    out.append(_sweep([(0.0, 0.0, top - 0.06), (0.0, 0.0, top + 0.1)], [0.11, 0.11], gold, seg=10, samples=1,
                      cap0=0, cap1=0, name="plumeholder"))
    # (the helm closes the top: a hanging Sir Sockington wants its _Pin here, so the clothespin's
    # jaws clip the plume holder instead of sinking into the dome)
    c.pin_z = top + 0.2
    for sx, sc, col in ((-1.0, 0.66, plume_d), (1.0, 0.66, plume_d), (0.0, 0.95, plume)):
        side = Vector((sx * 0.15, 0.0, 0.0))
        pts = [Vector((0.0, 0.0, top + 0.05)), Vector((0.0, 0.03, top + 0.4 * sc)) + side * 0.4,
               Vector((0.0, 0.22, top + 0.68 * sc)) + side * 0.8, Vector((0.0, 0.55, top + 0.74 * sc)) + side,
               Vector((0.0, 0.88, top + 0.52 * sc)) + side * 1.1, Vector((0.0, 1.04, top + 0.2 * sc)) + side * 1.1]
        out.append(_sweep(pts, [0.12 * sc, 0.21 * sc, 0.24 * sc, 0.23 * sc, 0.17 * sc, 0.08], col, seg=8, samples=3,
                          cap0=0.6, cap1=0.9, flat=0.55, up=Vector((1.0, 0.0, -sx * 0.4)), name="plume"))
    # breastplate: from just under the helm down over the ankle, a shield-shaped bottom edge, a chest
    # bulge, gold trim along its top and bottom edges, a red diamond emblem in gold on the bulge
    zp1 = z_b - 0.14
    aw = 1.4

    def zbot(a):
        t = min(abs(a) / aw, 1.0)
        return c.instep_z - 0.42 + 0.62 * t ** 1.4

    def bulge(a, v):
        return 0.03 + 0.08 * max(math.cos(a), 0.0) ** 2 * math.sin(math.pi * (0.12 + 0.76 * (1.0 - v)))

    def plate(u, v):
        a = (u - 0.5) * 2 * aw
        return a, _lerp(zp1, zbot(a), v), bulge(a, v)

    tp = 0.06
    out.append(_shell(c, 20, 6, plate, tp, steel, wall_pal=steel_d, name="breastplate"))

    def edge(v, k0=0, k1=20):
        pts = []
        for k in range(k0, k1 + 1):
            a = (k / 20 - 0.5) * 2 * aw
            pnt, nn = c.surface(a, _lerp(zp1, zbot(a), v))
            pts.append(pnt + nn * (bulge(a, v) + tp))
        return pts

    for v in (0.0, 1.0):
        pts = edge(v)
        out.append(_sweep(pts, [0.045] * len(pts), gold, seg=6, samples=1, cap0=0.0, cap1=0.0, name="platetrim"))
    # side edges: short gold caps so the trims end flush with the plate
    for k in (0, 20):
        a = (k / 20 - 0.5) * 2 * aw
        pts = []
        for j in range(7):
            v = j / 6
            pnt, nn = c.surface(a, _lerp(zp1, zbot(a), v))
            pts.append(pnt + nn * (bulge(a, v) + tp * 0.5))
        out.append(_sweep(pts, [0.04] * 7, gold, seg=6, samples=2, cap0=0.0, cap1=0.0, name="plateside"))
    # a leather strap round the back holding the plate on
    zs_ = _lerp(zp1, zbot(aw), 0.4)
    ab = [aw - 0.05 + (TAU - 2 * aw + 0.1) * k / 16 for k in range(17)]
    spts = [c.surface(a, zs_, 0.03)[0] for a in ab]
    out.append(_sweep(spts, [0.085] * len(spts), strap, seg=8, samples=1, cap0=0, cap1=0, flat=0.35,
                      up=c.surface(ab[0], zs_)[1], name="strap"))
    # the emblem: centred on the chest bulge, <= 0.45 of the plate's height
    ve = 0.42
    pnt, nn = c.surface(0.0, _lerp(zp1, zbot(0.0), ve))
    base = pnt + nn * (bulge(0.0, ve) + tp)
    # (an ink diamond just behind it draws a snug border; a hull would float off the curved plate)
    out.append(_puck(base + nn * 0.0, nn, Z, 0.24, 0.32, 0.04, K.BLACK, p=1.0, bevel=0.2, seg=16, rings=2,
                     outline=False, name="emblem_ink"))
    out.append(_puck(base + nn * 0.016, nn, Z, 0.2, 0.27, 0.05, gold, p=1.0, bevel=0.2, seg=16, rings=2,
                     outline=False, name="emblem"))
    out.append(_puck(base + nn * 0.042, nn, Z, 0.13, 0.18, 0.04, plume, p=1.0, bevel=0.25, seg=16, rings=2,
                     outline=False, name="emblem_in"))
    return out


# Per-type tweaks merged over socks.SPECS (colours, mood, tall/short, ...). Never change `single`.
SPEC_OVERRIDES = {
    # three white stripes right under the rim (no cuff band), the face under them
    "KneeHigh": dict(cuff="body", cuff_h=0.2,
                     stripes=[(5.34, 5.47, "accent"), (5.05, 5.18, "accent"), (4.76, 4.89, "accent")],
                     face_drop=1.52),
    # the fluffy roll covers the cuff band
    "Slipperino": dict(cuff="body", face_drop=0.86),
    # the red bands are cut into the body here and pinched in by feat_compressio; own open mouth
    "Compressio": dict(body="#595968", dark="#34343F",
                       stripes=[(2.12, 2.24, "accent"), (2.48, 2.6, "accent")], mouth=False),
    # grey sock under bright steel armour; the helm hides the mouth (its visor slit frowns instead)
    "Sockington": dict(body="#7A8192", dark="#5C6272", cuff="body", mouth=False, mood="happy"),
}

FEATURES = {
    "KneeHigh": feat_kneehigh,
    "Slipperino": feat_slipperino,
    "Compressio": feat_compressio,
    "Sockhopper": feat_sockhopper,
    "DJDryer": feat_djdryer,
    "Socktopus": feat_socktopus,
    "Sockington": feat_sockington,
}
