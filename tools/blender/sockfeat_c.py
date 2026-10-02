"""
sockfeat_c.py - signature features for Stinkolino, SockNess, Shockini, Lintlord, Zillionaire, LostSock, PuppetSupreme.

Each feature builder takes the SockCtx `c` built by socks.py (body shape, eye/mouth positions,
surface helpers, colours) and returns a list of sockkit Pieces added on top of the shared body.
Only rely on SockCtx fields - never hard-code body dimensions - so the body can be reshaped without
breaking the features. Colour names must be prefixed with the type id (first registration wins).

None of these seven has sheet art: each is designed in the character sheet's style (the shared
body, googly eyes and ink outline; body colour + darker heel/toe + cuff) with ONE big idea that
reads from any side and from far away:
  Stinkolino     a puff of green gas in the opening with three wavy stink lines rising out of it
                 and fanning apart (flat S-waves, thin at the top), one more rising off the toe tip
                 out of its own puff, three flies (big pale wings, a dotted loop-the-loop behind each),
                 a sweat stain on the back, a dark cuff; a queasy face: one eye squeezed nearly shut
                 under a lid that stays inside the eye's ink rim, the other wide under a wobbly brow,
                 bags, soft olive cheeks, a wobbly open 'bleh' mouth with the tongue lolling out,
                 widening toward its tip, which curls off toward the toe
  SockNess       a cute Loch Ness sea serpent: a teal ankle sock (light ribbed cuff, dark heel/toe)
                 out of whose opening (dark lip showing all round) rises a tapering neck whose curve
                 turns in 3D - back over the heel, across to the toe side, forward into the head - so
                 it is a curve from every side (never a straight column); a big head (about twice the
                 neck's width) yawed toward the toe side (the muzzle in profile from the front) with
                 the googly eyes moved on top, mint fan frills either side and a long friendly snout
                 (nostrils, smile, pink cheeks); ONE centred row of rounded-triangle mint fins down
                 the head, neck and sock back to the heel (a zig-zag crest); one continuous segmented
                 mint belly strip down the throat; the foot in a suds puddle (rolled, lumpy foam bead,
                 tinted soap bubbles) trailing off behind the heel, where two humps (daylight under
                 each arch, mint undersides) and the tail tip rise out of the foam
  Shockini       hair standing on end: a dandelion burst of pale-yellow zig-zag strands (thin ink
                 lines) out of a fuzzy tuft, kinked static hairs on the sides and back, a blue zig-zag
                 stripe, four chunky bolts at staggered heights clear of the face, sparks; shocked
                 face: pinpoint pupils, high brows under a narrow dark cuff, a big open oval mouth
  Lintlord       a gold crown (ball-tipped points, gems, red velvet cap) on a ruff of round lint
                 puffs; the sock wrapped in four big soft lint drifts - light warm lavender-grey (a
                 clear step above the grey sock), pillows with a rolled bead and bumpy cloud edges that
                 also rise and dip (soft from edge-on), a few darker strand lines on top, one clean
                 ink line each - wrapping round the leg's edges: toe side -> back, heel side -> back
                 up into the ruff, over the heel, over the toe and up the instep; fat soft S-curled
                 lint wisps off the ruff and the side drifts; smug half-lids
  Zillionaire    a black top hat (its hollow has no ink hull) with a green band and a tucked bill,
                 a flat inked handlebar moustache with curled-up tips, monocle and chain, three bright
                 gold-thread bands mid-leg, a 3D fountain of bills bursting out of the hat
  LostSock       navy; a ghostly lavender-blue floating question mark (core stripe, halo ring round
                 the dot, thin ink line, turned and bent in depth so it reads from the side), a tear,
                 a darned patch, a frayed hole and loose thread
  PuppetSupreme  a huge open red puppet mouth (fat lips, four teeth, a tongue), flat dark-red button
                 discs behind the googly eyes (thread holes on the ring outside each eye) and a yellow
                 yarn mop (thin ink) flopping over the rim, ragged at the back with a few long strands
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, color, hexcol  # noqa: F401
import socks as S
from socks import (C_BLUEBOLT, C_CASH, C_DARK, C_GOLD, C_GOLD2, C_GREEN, C_GREY, C_MAGENTA,  # noqa: F401
                   C_PINKMOUTH, C_RED, C_SILVER, C_SILVER2, C_STINK, C_TONGUE, C_WICKER, C_WICKER2)

TAU = math.tau
Z = Vector((0.0, 0.0, 1.0))
_lerp, _smooth = S._lerp, S._smooth

# colours used by the spec stripes must exist before body_pieces() runs (it looks them up by name)
C_ZIL_THREAD = hexcol("Zillionaire_thread", "#FFF0A0")
C_ZIL_THREAD_EDGE = hexcol("Zillionaire_thread_edge", "#9C6A16")


# ------------------------------------------------------------------ geometry helpers
def _piece(bm, pals, name, outline=True, smooth=True):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pals, outline, smooth, name)


def _frame(n, up=Z):
    """4x4 rotation: local +Z = n, local +Y = `up` made perpendicular to n, local +X = Y x Z."""
    n = Vector(n).normalized()
    u = Vector(up) - n * Vector(up).dot(n)
    if u.length < 1e-6:
        u = Vector((0.0, 1.0, 0.0)) - n * n.y
    u.normalize()
    x = u.cross(n)
    return Matrix((x, u, n)).transposed().to_4x4()


def _resample(pts, radii, samples):
    pts = [Vector(p) for p in pts]
    if samples <= 1 or len(pts) < 2:
        return pts, list(radii)
    P = S._catmull(pts, samples)
    R = [radii[0]]
    for k in range(1, len(P)):
        i, f = (k - 1) // samples, ((k - 1) % samples + 1) / samples
        R.append(_lerp(radii[i], radii[i + 1], _smooth(f)))
    return P, R


def _sweep(pts, radii, pal, seg=10, samples=4, cap0=1.0, cap1=1.0, flat=1.0, up=None, closed=False,
           pal_fn=None, outline=True, smooth=True, cap_rings=3, name="sweep"):
    """A tube through pts (Catmull-Rom, `samples` per segment) with per-point radii and
    rotation-minimising frames. Cross-section: an ellipse, r * flat along the frame normal (starts
    as `up` made perpendicular to the path), r across. cap0/cap1: None open, 0 flat, > 0 a dome
    that many radii long. closed: a loop (pass dense pts). pal_fn(s, ph, centre) colours faces."""
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
        n = N[-1]
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
            pals.append(col(0.0, (j + 0.5) / seg, f))
    pairs = [(a, a + 1) for a in range(nr - 1)] + ([(nr - 1, 0)] if closed else [])
    for a, b in pairs:
        for j in range(seg):
            j2 = (j + 1) % seg
            f = bm.faces.new((rings[a][j], rings[a][j2], rings[b][j2], rings[b][j]))
            pals.append(col((svals[a] + svals[b]) / 2, (j + 0.5) / seg, f))
    if tips[1] is not None:
        for j in range(seg):
            f = bm.faces.new((rings[-1][j], rings[-1][(j + 1) % seg], tips[1]))
            pals.append(col(1.0, (j + 0.5) / seg, f))
    bm.normal_update()
    # make the faces point outward (the frame handedness decides the winding)
    bm.faces.ensure_lookup_table()
    k0 = len(pals) // 2
    f0 = bm.faces[k0]
    ci = min(range(m), key=lambda k: (P[k] - f0.calc_center_median()).length)
    if f0.normal.dot(f0.calc_center_median() - P[ci]) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    return _piece(bm, pals, name, outline, smooth)


def _lathe(profile, pal, seg=20, mat=None, pal_fn=None, outline=True, smooth=True, name="lathe", phase=0.0):
    """Surface of revolution about local +Z from (r, z) points listed bottom -> top along the
    outside (r = 0 makes a pole). pal_fn(k, j, centre) colours faces (k = profile segment)."""
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


def _prism(poly, depth, mat, pal, bevel=0.03, segs=2, outline=True, name="prism"):
    """A flat shape (2D outline in local XY, any winding, may be concave) extruded `depth` along
    local Z and centred on it, edges rounded by a bevel; moved by `mat`. Flat shaded."""
    bm = bmesh.new()
    vf = [bm.verts.new((x, y, depth / 2)) for x, y in poly]
    vb = [bm.verts.new((x, y, -depth / 2)) for x, y in poly]
    n = len(poly)
    bm.faces.new(vf)
    bm.faces.new(list(reversed(vb)))
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((vf[i], vb[i], vb[j], vf[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    K.link(obj)
    obj.matrix_world = mat
    if bevel > 0:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = segs
        mod.limit_method = "ANGLE"
        mod.angle_limit = math.radians(30)
    tri = obj.modifiers.new("tri", "TRIANGULATE")
    tri.min_vertices = 5
    return K.Piece(K.bake_object(obj), pal, outline, False, name)


def _conform(c, nu, nv, grid, lift, thick, pal, wrap=False, pal_fn=None, surf=None, outline=False, name="plate"):
    """A slab hugging a surface: grid(u, v) -> (a, b) for u, v in 0..1; surf(a, b) -> (point,
    normal) (default c.surface(angle, z)). Its back sits `lift` off the surface, its front `thick`
    further. wrap: u = 1 joins u = 0 (a band round the leg). pal_fn(u, v, centre) colours the front."""
    surf = surf or c.surface
    bm = bmesh.new()
    cols = nu if wrap else nu + 1
    inner, outer, nrm = {}, {}, {}
    for i in range(cols):
        for k in range(nv + 1):
            a, b = grid(i / nu, k / nv)
            p, n = surf(a, b)
            inner[i, k] = bm.verts.new(p + n * lift)
            outer[i, k] = bm.verts.new(p + n * (lift + thick))
            nrm[i, k] = n

    def I(i):
        return i % nu if wrap else i

    pals = []

    def face(vs, want, pal_):
        f = bm.faces.new(vs)
        f.normal_update()
        if f.normal.dot(want) < 0:
            f.normal_flip()
        pals.append(pal_)

    for i in range(nu):
        for k in range(nv):
            q = [(I(i), k), (I(i + 1), k), (I(i + 1), k + 1), (I(i), k + 1)]
            nn = sum((nrm[t] for t in q), Vector())
            cen = sum((outer[t].co for t in q), Vector()) / 4
            face([outer[t] for t in q], nn, pal_fn((i + 0.5) / nu, (k + 0.5) / nv, cen) if pal_fn else pal)
            face([inner[t] for t in reversed(q)], -nn, pal)
            edges = []
            if k == 0:
                edges.append((q[0], q[1]))
            if k == nv - 1:
                edges.append((q[2], q[3]))
            if not wrap and i == 0:
                edges.append((q[3], q[0]))
            if not wrap and i == nu - 1:
                edges.append((q[1], q[2]))
            for ta, tb in edges:
                mid = (outer[ta].co + outer[tb].co) / 2
                face([outer[ta], outer[tb], inner[tb], inner[ta]], mid - cen, pal)
    return _piece(bm, pals, name, outline, True)


def _ink_line(c, pts_xz, lift=0.012, radius=S.INK, taper=1.0, samples=3, name="ink"):
    """An ink stroke on the face through (x, z) points (rides over the eyes like face_point)."""
    hits = [c.face_point(x, z, lift) for x, z in pts_xz]
    return S._ink([p for p, _n in hits], [n for _p, n in hits], radius, taper=taper, samples=samples, name=name)


def _lid(c, i, pal, tilt, ang, lean=0.15, lift=0.036, line_r=0.042, name="lid", clip=0.0):
    """An eyelid over eye i: a cap of colour `pal` over the part of the eyeball within `ang` radians
    of an axis `tilt` radians up from the eye's OUTER side (pi/2 = straight up, more than pi/2 =
    leaning toward the nose), plus an ink line along the lid's visible edge - only where the edge
    faces forward more than `clip` (0..1), so its ends never reach round past the eye's outline."""
    T, wrap = c.eye_mats[i], c.eye_wrap[i]
    ctr = Vector(c.eyes[i])
    s = -1.0 if ctr.x < 0 else 1.0
    ax = Vector((s * math.cos(tilt), math.sin(tilt), lean)).normalized()
    lid = S._cap(pal, ax, ang, T, lift=lift, seg=16, rings=3, name=name)
    Tn = T.to_3x3().inverted().transposed()
    e1 = Vector((0.0, 0.0, 1.0))
    e1 = (e1 - ax * e1.dot(ax)).normalized()
    e2 = ax.cross(e1).normalized()
    run = []
    nk = 5 if clip <= 0.0 else 9
    for k in range(nk):
        ph = -math.pi / 2 + math.pi * k / (nk - 1)
        q = ax * math.cos(ang) + (e1 * math.cos(ph) + e2 * math.sin(ph)) * math.sin(ang)
        if q.z > clip:
            run.append(q)
    pts = [T @ q + (Tn @ q).normalized() * (lift + 0.006) for q in run]
    nrms = [(Tn @ q).normalized() for q in run]
    line = S._ink(pts, nrms, line_r, samples=2 if clip <= 0.0 else 1, name=name + "line")
    S._wrap_pieces([lid, line], wrap)
    return [lid, line]


def _eyelid(c, i, pal, yl, rho=0.85, lift=0.03, line_r=0.04, nu=12, nv=4, name="lid"):
    """An upper eyelid over eye i that stays INSIDE the eye's ink rim: it covers the part of the
    eyeball's front (unit-sphere coordinates before the eye matrix: +X right, +Y up, +Z out) above
    the curve y = yl(x) and within rho of the eye's axis (the white shows up to ~0.9, so the rim's
    own edge stays clean); plus one ink line along its lower edge. The lid is lifted `lift` along
    the ball's normal, so it sits in front of the rim bead where they overlap."""
    T, wrap = c.eye_mats[i], c.eye_wrap[i]
    Tn = T.to_3x3().inverted().transposed()
    xs = [_lerp(-rho, rho, k / 200) for k in range(201)]
    inside = [x for x in xs if yl(x) < math.sqrt(max(rho * rho - x * x, 0.0)) - 1e-3]
    if not inside:
        return []
    xa, xb = inside[0], inside[-1]

    def world(x, y, extra=0.0):
        q = Vector((x, y, math.sqrt(max(1.0 - x * x - y * y, 0.0))))
        nn = (Tn @ q).normalized()
        return T @ q + nn * (lift + extra), nn

    bm = bmesh.new()
    cols = []
    for k in range(nu + 1):
        x = _lerp(xa, xb, k / nu)
        y1 = math.sqrt(max(rho * rho - x * x, 0.0))
        y0 = min(max(yl(x), -y1), y1)
        cols.append([bm.verts.new(world(x, _lerp(y0, y1, j / nv))[0]) for j in range(nv + 1)])
    for k in range(nu):
        for j in range(nv):
            bm.faces.new((cols[k][j], cols[k + 1][j], cols[k + 1][j + 1], cols[k][j + 1]))
    bm.normal_update()
    bm.faces.ensure_lookup_table()
    f0 = bm.faces[len(bm.faces) // 2]
    if f0.normal.dot(f0.calc_center_median() - Vector(c.eyes[i])) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    lid = _piece(bm, pal, name, outline=False, smooth=True)
    pts, nrms = [], []
    for k in range(7):
        x = _lerp(xa, xb, k / 6)
        p, nn = world(x, yl(x), 0.006)
        pts.append(p)
        nrms.append(nn)
    line = S._ink(pts, nrms, line_r, samples=2, taper=0.6, name=name + "line")
    S._wrap_pieces([lid, line], wrap)
    return [lid, line]


def _lids(c, pal, tilt, ang, lean=0.15, lift=0.036, line_r=0.042, name="lid", clip=0.0):
    """The same eyelid (see _lid) over both eyes."""
    out = []
    for i in range(len(c.eyes)):
        out += _lid(c, i, pal, tilt, ang, lean, lift, line_r, name, clip)
    return out


def _leg_patch(c, ang, z, w, hgt, lift, thick, pal, border=0.0, ink_lift=None, n=6, spin=0.0):
    """A rectangular plate on the leg (centre angle / z, width w and height hgt in world units),
    conforming to the surface, optionally on a black plate `border` bigger on every side."""
    r = c.radius_at(z, ang)
    out = []
    for g, lf, pl in (((border, lift, K.BLACK),) if border > 0 else ()) + ((0.0, lift + (0.012 if border > 0 else 0.0), pal),):
        hw, hh = w / 2 + g, hgt / 2 + g

        def grid(u, v, hw=hw, hh=hh):
            x, y = _lerp(-hw, hw, u), _lerp(-hh, hh, v)
            cs, sn = math.cos(spin), math.sin(spin)
            x, y = x * cs - y * sn, x * sn + y * cs
            return ang + x / r, z + y
        out.append(_conform(c, n, n, grid, lf, thick, pl, name="patch"))
    return out


def _blob_decal(c, ang, z, rfn, lift, thick, pal, rings=3, seg=16, surf=None, name="blob"):
    """A flat colour blob on the leg: centre (angle, z), outline radius rfn(theta) in world units
    (theta round the blob, 0 = +angle direction), conforming to the surface, `thick` deep."""
    surf = surf or c.surface
    r = c.radius_at(z, ang)
    bm = bmesh.new()

    def at(rho, th):
        rr = rfn(th) * rho
        p, n = surf(ang + rr * math.cos(th) / r, z + rr * math.sin(th))
        return p, n

    p0, n0 = at(0.0, 0.0)
    cf, cb = bm.verts.new(p0 + n0 * (lift + thick)), bm.verts.new(p0 + n0 * lift)
    fr, br = [], []
    for k in range(1, rings + 1):
        rho = k / rings
        rf, rb = [], []
        for j in range(seg):
            p, n = at(rho, TAU * j / seg)
            rf.append(bm.verts.new(p + n * (lift + thick)))
            rb.append(bm.verts.new(p + n * lift))
        fr.append(rf)
        br.append(rb)
    for j in range(seg):
        j2 = (j + 1) % seg
        bm.faces.new((cf, fr[0][j], fr[0][j2]))
        bm.faces.new((cb, br[0][j2], br[0][j]))
        for k in range(rings - 1):
            bm.faces.new((fr[k][j], fr[k + 1][j], fr[k + 1][j2], fr[k][j2]))
            bm.faces.new((br[k][j2], br[k + 1][j2], br[k + 1][j], br[k][j]))
        bm.faces.new((fr[-1][j], br[-1][j], br[-1][j2], fr[-1][j2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _piece(bm, pal, name, outline=False, smooth=True)


def _rnd(i, k=0):
    """Deterministic pseudo-random number in [0, 1) (same model every build)."""
    x = math.sin(i * 12.9898 + k * 78.233 + 0.5) * 43758.5453
    return x - math.floor(x)


def _blob(pal, ctr, rot3, radii, seg=7, rings=3, cut=-0.3, lump=0.0, seed=0, outline=True, closed=True, stagger=True,
          name="blob"):
    """A (lumpy) ellipsoid cap: the part of the unit sphere above local z = cut, closed by a flat
    bottom (closed=False leaves it open: for caps sunk into a surface), scaled by radii along rot3's
    columns (local Z = rot3's third column) and centred at ctr. Cheap soft bumps (lint tufts, suds):
    seg * (2 * rings - 1) triangles (+ seg - 2 for the bottom). lump > 0 wobbles each vertex's
    radius by up to that fraction."""
    th_cut = math.acos(max(-0.95, min(0.95, cut)))
    bm = bmesh.new()
    top = bm.verts.new((0.0, 0.0, 1.0))
    rings_v = []
    for r in range(1, rings + 1):
        th = th_cut * r / rings
        ring = []
        for j in range(seg):
            ph = TAU * (j + (0.37 * (r % 2) if stagger else 0.0)) / seg
            w = 1.0 + lump * (2.0 * _rnd(seed * 37 + r * 11 + j, 3) - 1.0)
            ring.append(bm.verts.new((math.sin(th) * math.cos(ph) * w, math.sin(th) * math.sin(ph) * w, math.cos(th))))
        rings_v.append(ring)
    for j in range(seg):
        bm.faces.new((top, rings_v[0][j], rings_v[0][(j + 1) % seg]))
    for ra, rb in zip(rings_v, rings_v[1:]):
        for j in range(seg):
            j2 = (j + 1) % seg
            bm.faces.new((ra[j], rb[j], rb[j2], ra[j2]))
    if closed:
        bm.faces.new(list(reversed(rings_v[-1])))
    R = rot3 if rot3 is not None else Matrix.Identity(3)
    for v in bm.verts:
        q = Vector((v.co.x * radii[0], v.co.y * radii[1], v.co.z * radii[2]))
        v.co = Vector(ctr) + R @ q
    bm.normal_update()
    if closed:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    else:
        bm.faces.ensure_lookup_table()
        f0 = bm.faces[0]
        if f0.normal.dot(f0.calc_center_median() - Vector(ctr)) < 0:
            bmesh.ops.reverse_faces(bm, faces=bm.faces)
    return _piece(bm, pal, name, outline, True)


HULL = 0.06   # outline width K.finish gives every piece with outline=True (socks.build_sock)


def _thin_inked(build, radii, width, min_r=0.004):
    """Parts that need a thinner ink line than the standard 0.06 hull (thin hair, yarn, a ghostly
    question mark): build(radii, pal, outline) makes the part; this returns [the part without a
    hull, a hidden inner copy shrunk by HULL - width that does get the hull], so the ink line
    ends up `width` (a number or per-point list) outside the part. The inner copy stays inside the
    part (never seen, never shadowing it - a hand-made flipped shell in the body would). Where the
    part is thinner than HULL - width the line is a little wider (the copy can't shrink below
    min_r)."""
    ws = width if isinstance(width, (list, tuple)) else [width] * len(radii)
    inner = [max(r - (HULL - w), min_r) for r, w in zip(radii, ws)]
    return [build(radii, None, False), build(inner, None, True)]


def _strand(pts, radii, pal, width=0.03, seg=5, samples=1, cap1=1.1, name="strand"):
    """A tapering strand (hair, yarn) with a thinner ink line (`width`) than the standard hull."""
    def build(rr, _pal, outline):
        return _sweep(pts, rr, pal, seg=seg, samples=samples, cap0=0.0, cap1=cap1, cap_rings=2, outline=outline,
                      name=name if not outline else name + "_core")
    return _thin_inked(build, radii, width)


def _ellipsoid(pal, ctr, radii, rot=None, seg=12, rings=8, outline=True, name="ell"):
    R = rot if rot is not None else Matrix.Identity(4)
    return K.sphere(pal, 1.0, Matrix.Translation(Vector(ctr)) @ R @ Matrix.Diagonal(Vector((*radii, 1.0))),
                    seg=seg, rings=rings, outline=outline, name=name)


def _smin(a, b, k):
    """Smooth minimum (soft union of two signed distances), blend width k."""
    hh = max(k - abs(a - b), 0.0) / k
    return min(a, b) - hh * hh * k * 0.25


def _smax(a, b, k):
    return -_smin(-a, -b, k)


def _star_mesh(F, C, pal, seg=28, thetas=None, rmax=2.6, step=0.02, outline=True, name="star"):
    """A closed surface around C (F(C) < 0) from a signed-distance-like function F(p) (< 0 inside):
    a UV sphere whose vertices are moved out along their rays to the first exit F = 0 (found by
    marching + bisection). `thetas` (radians from +Z, 0 and pi excluded) sets the ring spacing."""
    C = Vector(C)
    thetas = thetas or [math.pi * i / 14 for i in range(1, 14)]

    def radius(u):
        lo, r = 0.0, step
        while r < rmax and F(C + u * r) < 0:
            lo, r = r, r + step
        hi = r
        for _i in range(16):
            mid = (lo + hi) / 2
            if F(C + u * mid) < 0:
                lo = mid
            else:
                hi = mid
        return (lo + hi) / 2

    bm = bmesh.new()
    top = bm.verts.new(C + Z * radius(Z))
    bot = bm.verts.new(C - Z * radius(-Z))
    rings = []
    for th in thetas:
        ring = []
        for j in range(seg):
            ph = TAU * j / seg
            u = Vector((math.sin(th) * math.sin(ph), -math.sin(th) * math.cos(ph), math.cos(th)))
            ring.append(bm.verts.new(C + u * radius(u)))
        rings.append(ring)
    for j in range(seg):
        j2 = (j + 1) % seg
        bm.faces.new((top, rings[0][j], rings[0][j2]))
        bm.faces.new((bot, rings[-1][j2], rings[-1][j]))
    for ra, rb in zip(rings, rings[1:]):
        for j in range(seg):
            j2 = (j + 1) % seg
            bm.faces.new((ra[j], rb[j], rb[j2], ra[j2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _piece(bm, pal, name, outline, True)


def _bvh(pieces):
    """A BVH over pieces' meshes (world space) -> ray(origin, dir) -> (point, normal) or None."""
    from mathutils.bvhtree import BVHTree
    verts, polys = [], []
    for p in pieces:
        o = len(verts)
        verts += [v.co.copy() for v in p.mesh.vertices]
        polys += [[o + i for i in f.vertices] for f in p.mesh.polygons]
    tree = BVHTree.FromPolygons(verts, polys)

    def ray(origin, dvec):
        loc, nrm, _i, _d = tree.ray_cast(Vector(origin), Vector(dvec).normalized())
        return None if loc is None else (loc, nrm.normalized())
    return ray


def _foot_point(c, t, phi, lift=0.0):
    """(point, normal) on the foot: t = 0..1 along the foot axis (leg axis -> toe tip), phi round
    the axis (0 = top, +pi/2 = toward -Y (front), pi = sole). None for singles / misses."""
    if not c.d:
        return None
    a0, a1 = c.foot_axis
    o = a0.lerp(a1, t)
    ax = (a1 - a0).normalized()
    up = Vector((0.0, 0.0, 1.0))
    up = (up - ax * up.dot(ax)).normalized()
    side = Vector((0.0, -1.0, 0.0))
    dvec = up * math.cos(phi) + side * math.sin(phi)
    hit = c.ray(o, dvec)
    if hit is None:
        return None
    p, n = hit
    return p + n * lift, n


# ------------------------------------------------------------------ Stinkolino Pestilini
def _fly(ctr, heading, s, dark, wing, eye):
    """A cartoon fly: round black body, small head with two white eyes, two big pale wings swept
    back and up in a V."""
    hd = Vector(heading).normalized()
    side = Z.cross(hd).normalized()
    up = hd.cross(side).normalized()
    rot = Matrix((hd, side, up)).transposed().to_4x4()      # local X forward, Y side, Z up
    out = [_ellipsoid(dark, ctr, (0.2 * s, 0.15 * s, 0.15 * s), rot, seg=8, rings=5, name="fly")]
    head = ctr + hd * (0.2 * s)
    out.append(K.sphere(dark, 0.1 * s, Matrix.Translation(head), seg=7, rings=4, name="flyhead"))
    for k in (-1, 1):
        out.append(K.sphere(eye, 0.05 * s, Matrix.Translation(head + hd * 0.05 * s + side * (k * 0.06 * s) + up * 0.04 * s),
                            seg=6, rings=3, outline=False, name="flyeye"))
        # wing: root on the back, long axis swept back, out and up; the wing plane tilts outward
        wdir = (-hd * math.cos(0.6) + side * (k * math.sin(0.6)))
        wdir = (wdir * math.cos(0.95) + up * math.sin(0.95)).normalized()
        wn = up - side * (k * 0.7)
        wn = (wn - wdir * wn.dot(wdir)).normalized()
        wy = wn.cross(wdir).normalized()
        wrot = Matrix((wdir, wy, wn)).transposed().to_4x4()
        wc = ctr + up * (0.11 * s) - hd * (0.03 * s) + wdir * (0.18 * s)
        out.append(_ellipsoid(wing, wc, (0.18 * s, 0.1 * s, 0.022 * s), wrot, seg=8, rings=4, name="wing"))
    return out


def feat_stinkolino(c):
    """A puff of green gas welling up out of the opening with three wavy stink lines rising out of
    it and fanning apart (flat S-waves, thick at the root and thin at the top), one more rising
    off the toe tip out of its own little puff, three flies each trailing a dotted loop-the-loop,
    a sweat stain on the back, and a queasy face: the toe-side eye squeezed nearly shut under a
    heavy lid, the other wide open under a wobbly raised brow, bags under both, soft sickly cheeks
    and a wobbly open 'bleh' mouth with the tongue lolling out over the lip toward the toe."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    stink = hexcol(f"{tid}_stink", "#BFE070")
    gas = hexcol(f"{tid}_gas", "#CBE68F")
    gas2 = hexcol(f"{tid}_gas_dark", "#A9CF62")
    fly_dark = hexcol(f"{tid}_fly", "#24202E")
    wing = hexcol(f"{tid}_wing", "#E2EEF7")
    tongue = hexcol(f"{tid}_tongue", "#F27A93")
    mouth_in = hexcol(f"{tid}_mouth", "#7E1F2D")
    sick = hexcol(f"{tid}_sick", "#A3BC52")
    out = []
    # a puff of gas welling up out of the opening (a lumpy cloud just over the rim)
    for k, (a, rr, z, r) in enumerate(((0.4, 0.2, -0.06, 0.4), (-2.0, 0.27, -0.08, 0.34), (2.3, 0.3, -0.1, 0.31))):
        a *= d
        p = Vector((math.sin(a) * rr, -math.cos(a) * rr, h + z))
        out.append(_blob(gas if k != 1 else gas2, p, None, (r, r, r * 0.62), seg=10, rings=3, cut=0.0, lump=0.06,
                         seed=k, name="gas"))

    def squiggle(base, lean, H, ph, waves=2.5, amp=0.11, r=0.075, n=11):
        """A flat S-wave rising H from base, drifting `lean` (Vector) over its height: it wiggles
        across `lean` (and a little along it, so it is not a flat ribbon from the side), thicker at
        the root, thin at the top."""
        ln = Vector(lean)
        fw = (ln - Z * ln.dot(Z))
        fw = fw.normalized() if fw.length > 1e-6 else Vector((1.0, 0.0, 0.0))
        tan = Z.cross(fw)
        pts, radii = [], []
        for i in range(n):
            t = i / (n - 1)
            w = TAU * waves * t + ph
            o = tan * (math.sin(w) * amp) + fw * (math.cos(w) * amp * 0.2) + ln * t
            pts.append(Vector(base) + o + Vector((0.0, 0.0, H * t)))
            radii.append(r * (0.72 + 0.3 * math.sin(math.pi * min(t * 1.6, 1.0))) * (1.0 - 0.55 * t))
        return _sweep(pts, radii, stink, seg=6, samples=2, cap0=1.0, cap1=1.0, cap_rings=2, name="stink")

    # three lines fanning out of the puff: one each side, one taller at the back in the middle
    # (side by side across the face direction, so the front and both 3/4 views keep them apart)
    for a, rr, z0, H, ph, lean in ((-1.57, 0.42, 0.02, 1.2, 0.4, 0.55), (1.57, 0.42, 0.02, 1.12, 2.6, 0.55),
                                   (math.pi, 0.12, 0.1, 1.32, 4.4, 0.1)):
        a *= d
        rad = Vector((math.sin(a), -math.cos(a), 0.0))
        out.append(squiggle(rad * rr + Vector((0.0, 0.0, h + z0)), rad * lean, H, ph))
    # one more rising off the toe tip, out of its own little puff of gas
    hit = c.ray(c.toe_c, Vector(c.toe_dir) + Vector((0.0, 0.0, 1.1)))
    tp, tn = hit if hit else (Vector(c.toe_tip), Vector(c.foot_dir))
    root = Vector(tp) + Vector(tn) * 0.05
    out.append(_blob(gas, root, None, (0.21, 0.19, 0.14), seg=10, rings=3, cut=-0.4, lump=0.08, seed=7, name="gas"))
    out.append(squiggle(root + Vector((0.0, 0.0, 0.1)), (0.12 * d, 0.0, 0.0), 0.9, 1.0, waves=1.5, amp=0.08, r=0.062, n=8))
    # a sweat stain on the back: a soft, darker olive blot
    stain = hexcol(f"{tid}_stain", "#6F7A35")
    out.append(_blob_decal(c, math.pi + 0.35 * d, c.instep_z + 0.95,
                           lambda th: 0.34 * (1.0 + 0.07 * math.sin(3 * th) + 0.04 * math.sin(5 * th + 1.0)),
                           0.004, 0.012, stain, rings=2, seg=20, name="stain"))
    # flies buzzing round it, clear of the stink lines, each trailing a dotted loop-the-loop
    # (two low beside the cuff, one above the lines' tops: no view lines a fly up inside a line)
    for a, R, z, s, turn in ((-1.75 * d, 1.45, h - 0.35, 1.1, 1), (1.62 * d, 1.55, h - 0.12, 1.0, -1),
                             (-0.6 * d, 1.0, h + 2.0, 0.95, 1)):
        p = Vector((math.sin(a) * R, -math.cos(a) * R, z))
        tang = Vector((math.cos(a), math.sin(a), 0.0)) * turn
        hd = (tang + Vector((0.0, 0.0, 0.25))).normalized()
        out += _fly(p, hd, s, fly_dark, wing, K.WHITE)
        side = Z.cross(hd).normalized()
        up = hd.cross(side).normalized()
        # a dotted loop (radius 0.15) just behind the fly in its heading/up plane: five separate
        # dots, gaps about twice their radius
        lc = p - hd * (0.36 * s) + up * (0.1 * s)
        lr = 0.15 * s
        for k in range(5):
            th = math.radians(-40.0 - 55.0 * k)
            q = lc + (hd * math.cos(th) + up * math.sin(th)) * lr - hd * (0.05 * k * s)
            out.append(K.sphere(fly_dark, 0.032 * s, Matrix.Translation(q), seg=6, rings=3, outline=False, name="trail"))
    # queasy eyes: the toe-side eye squeezed nearly shut under a heavy lid, the other wide open
    # under a small drooping lid and a wobbly raised brow; dark bags under both
    shut = 1 if d > 0 else 0
    wide = 1 - shut
    so_s = 1.0 if c.eyes[shut][0] > 0 else -1.0       # outward (away from the nose) in eye-local x
    so_w = -so_s
    out += _eyelid(c, shut, c.body, lambda x: -0.05 - 0.3 * (1.0 - min((x / 0.85) ** 2, 1.0)) - 0.12 * x * so_s,
                   line_r=0.045, name="lid")
    out += _eyelid(c, wide, c.body, lambda x: 0.5 - 0.12 * x * so_w, line_r=0.036, name="lid")
    ew = Vector(c.eyes[wide])
    sw = 1.0 if ew.x > 0 else -1.0
    top = ew.z + c.eye_r
    out.append(_ink_line(c, [(ew.x + sw * 0.24, top + 0.06), (ew.x + sw * 0.08, top + 0.15), (ew.x - sw * 0.05, top + 0.11),
                             (ew.x - sw * 0.19, top + 0.17)], radius=0.045, taper=0.45, samples=2, name="brow"))
    for i in (0, 1):
        e = Vector(c.eyes[i])
        si = 1.0 if e.x > 0 else -1.0
        zb = e.z - c.eye_rim_r - 0.035
        out.append(_ink_line(c, [(e.x - si * 0.15, zb + 0.03), (e.x - si * 0.02, zb - 0.015), (e.x + si * 0.13, zb + 0.015)],
                             radius=0.022, taper=0.4, samples=2, name="bag"))
    # soft sickly cheeks: round, a slightly lighter yellower olive than the body
    for k, a in enumerate((-0.95, 0.95)):
        out.append(_blob_decal(c, a, c.mouth_z + 0.04,
                               lambda th, k=k: 0.15 * (1.0 + 0.05 * math.sin(2 * th + k) + 0.03 * math.sin(3 * th + k * 2.0)),
                               0.005, 0.012, sick, rings=2, seg=18, name="cheek"))
    # a wobbly open 'bleh' mouth (dark red, inked, wavy top edge, lopsided toward the toe) with the
    # tongue lolling out of it over the lower lip
    cx, cz, w = 0.02 * d, c.mouth_z + 0.05, 0.26

    def mouth(g):
        ww = w + g

        def top(u):
            q = (u - cx) / ww
            return cz + 0.07 + 0.028 * math.sin(q * 3.0 * math.pi + 0.6) - 0.05 * q * d + g

        def bot(u):
            q = min(abs((u - cx) / ww), 1.0)
            return top(u) - g - (0.25 + 0.04 * (u - cx) * d / w) * max(1.0 - q ** 2.4, 0.0) ** 0.6 - g
        return cx - ww, cx + ww, top, bot
    out += S._inked(c.face_point, mouth, mouth_in, border=0.032, lift=0.026, n=13, name="mouthin")
    # tongue: out of the mouth, down over the lower lip, widening toward the tip, which curls off
    # toward the toe side; it lies close to the face and has a thin ink line
    tx = cx + 0.1 * d
    radii = [0.075, 0.095, 0.115, 0.13, 0.12]
    flat = 0.42
    path = [(tx, cz - 0.08), (tx + 0.01 * d, cz - 0.2), (tx + 0.04 * d, cz - 0.32), (tx + 0.1 * d, cz - 0.42),
            (tx + 0.18 * d, cz - 0.45)]
    pts, nrms = [], []
    for (x, z), r in zip(path, radii):
        p, n = c.face_point(x, z, r * flat * 0.9 + 0.03)
        pts.append(p)
        nrms.append(n)
    out += _thin_inked(lambda rr, _p, ol: _sweep(pts, rr, tongue, seg=8, samples=3, cap0=1.0, cap1=1.0, flat=flat,
                                                 up=nrms[1], outline=ol, name="tongue"), radii, 0.03)
    # crease: a short open line out of the mouth (its top end is lost in the dark mouth) down
    # about 40% of the tongue
    cp = [pts[0] + (pts[0] - pts[1]) * 0.3, pts[0], pts[0].lerp(pts[1], 0.55), pts[1].lerp(pts[2], 0.15)]
    cn = [nrms[0], nrms[0], nrms[0].lerp(nrms[1], 0.55), nrms[1]]
    cr = [radii[0], radii[0], _lerp(radii[0], radii[1], 0.55), radii[1]]
    out.append(S._ink([p + n * (r * flat + 0.008) for p, n, r in zip(cp, cn, cr)], cn, 0.015, samples=2, taper=0.3,
                      name="crease"))
    return out


# ------------------------------------------------------------------ The Sock Ness Monster
def _arc(pts):
    """Arclength-parametrised polyline: f(s in 0..1) -> (point, unit tangent); the tangent is blended
    between the vertices' (central-difference) tangents, so frames built on it turn smoothly."""
    P = [Vector(p) for p in pts]
    acc = [0.0]
    for a, b in zip(P, P[1:]):
        acc.append(acc[-1] + (b - a).length)
    tot = max(acc[-1], 1e-9)
    TV = [(P[min(i + 1, len(P) - 1)] - P[max(i - 1, 0)]).normalized() for i in range(len(P))]

    def f(s):
        x = max(0.0, min(1.0, s)) * tot
        k = 0
        while k < len(P) - 2 and acc[k + 1] < x:
            k += 1
        t = max(0.0, min(1.0, (x - acc[k]) / max(acc[k + 1] - acc[k], 1e-9)))
        return P[k].lerp(P[k + 1], t), TV[k].lerp(TV[k + 1], t).normalized()
    return f


def _move_face(c, mat):
    """Moves the googly eyes socks.face_pieces built on the leg (eyeballs, ink rims, pupils, glints:
    every mesh not merged yet whose vertices all lie near an eye centre) rigidly by `mat`, and the
    eye bookkeeping in c with them. face_point() no longer rides over them afterwards."""
    eyes = [Vector(e) for e in c.eyes]
    reach = c.eye_rim_r + 0.12
    for me in list(bpy.data.meshes):
        if me.users or not len(me.vertices):
            continue
        if all(min((v.co - e).length for e in eyes) <= reach for v in me.vertices):
            me.transform(mat)
    r3 = mat.to_3x3()
    c.eyes = [tuple(mat @ Vector(e)) for e in c.eyes]
    c.pupils = [tuple(mat @ Vector(p)) for p in c.pupils]
    c.eye_n = [(r3 @ Vector(n)).normalized() for n in c.eye_n]
    c.eye_mats = [mat @ T for T in c.eye_mats]
    c.ey = sum(e[2] for e in c.eyes) / len(c.eyes)
    c._eye_solids = []


def _fin(pal, p, n, along, L, H, thick, sink=0.3, lean=0.22, bulge=0.05, apex_pts=5, name="fin"):
    """A rounded-triangle dorsal fin standing on a surface at p (outward normal n): its base is L long
    along `along`, its apex H above the surface, leaning lean * L toward +along (point `along` at the
    tail and the fins sweep back), the corners rounded and the sides bulging a little. Cross-section:
    a soft pillow, `thick` (half) thick in the middle thinning to a rounded edge, so from the side it
    is one smooth rounded triangle with a clean ink line and from the front / back a slim lens. Its
    foot sinks sink * H into the surface. 6 * (apex_pts + 7) triangles."""
    n = Vector(n).normalized()
    along = Vector(along)
    along = (along - n * along.dot(n)).normalized()
    across = along.cross(n).normalized()
    V = [Vector((-L / 2, -sink * H)), Vector((L / 2, -sink * H)), Vector((lean * L, H))]   # (along, up), CCW
    rr = [0.06 * L, 0.06 * L, min(0.3 * L, 0.24 * H)]

    def onorm(a, b):
        e = (b - a).normalized()
        return Vector((e.y, -e.x))

    cens = []
    for i in range(3):
        u0, u1 = (V[i - 1] - V[i]).normalized(), (V[(i + 1) % 3] - V[i]).normalized()
        half = 0.5 * math.acos(max(-1.0, min(1.0, u0.dot(u1))))
        cens.append(V[i] + (u0 + u1).normalized() * (rr[i] / math.sin(half)))
    outline = []
    for i in range(3):
        j = (i + 1) % 3
        n0, n1 = onorm(V[i - 1], V[i]), onorm(V[i], V[j])
        f0, f1 = math.atan2(n0.y, n0.x), math.atan2(n1.y, n1.x)
        while f1 < f0:
            f1 += TAU
        m = apex_pts if i == 2 else 2
        for t in range(m):
            f = _lerp(f0, f1, t / (m - 1))
            outline.append(cens[i] + Vector((math.cos(f), math.sin(f))) * rr[i])
        e0, e1 = cens[i] + n1 * rr[i], cens[j] + n1 * rr[j]
        outline.append((e0 + e1) / 2 + n1 * (bulge * (e1 - e0).length))
    G = (V[0] + V[1] + V[2]) / 3
    bm = bmesh.new()

    def world(q, w):
        return Vector(p) + along * q.x + n * q.y + across * w

    rim = [bm.verts.new(world(q, 0.0)) for q in outline]
    m = len(outline)
    for sg in (1.0, -1.0):
        mid = [bm.verts.new(world(G + (q - G) * 0.6, sg * thick * 0.85)) for q in outline]
        ctr = bm.verts.new(world(G, sg * thick))
        for j in range(m):
            j2 = (j + 1) % m
            bm.faces.new((ctr, mid[j], mid[j2]))
            bm.faces.new((mid[j], rim[j], rim[j2], mid[j2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _piece(bm, pal, name, outline=True, smooth=True)


def feat_sockness(c):
    """A cute Loch Ness sea serpent: a teal ankle sock out of whose opening (its dark lip showing all
    round) rises a long, tapering neck. The neck's curve turns in 3D: it bows straight back first,
    then swings over to the toe side and up into a big head facing forward, so it is a curve from
    every side - a question mark from the side, a C leaning over the toe from the front and the back,
    an S from the 3/4 views - never a straight column. The head (a round cranium about twice as wide
    as the neck, yawed ~24 deg toward the toe side so the muzzle shows in profile from the front, the
    googly eyes moved on top, a long friendly snout with nostrils, a smile and pink cheeks, mint fan
    frills either side facing front and back) is clearly wider than the neck from every side. ONE
    centred row of rounded-triangle mint fins runs down the back of the head, the neck and the sock
    to the heel (a zig-zag crest along the outline); one continuous mint belly strip of five soft
    segments follows the throat. The foot stands in a suds puddle (a rolled, lumpy foam bead, foam
    clumps, three tinted soap bubbles) that trails off behind the heel, where two humps of the
    serpent's body (daylight under each arch) and the tip of its tail rise out of the foam."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    acc = c.accent
    nostril = hexcol(f"{tid}_nostril", "#14504C")
    cheek = hexcol(f"{tid}_cheek", "#F29AA6")
    foam = hexcol(f"{tid}_foam", "#F4FAFF")
    foam2 = hexcol(f"{tid}_foam2", "#CDEAF7")
    out = []
    k = c.RL / 0.7                                   # proportions follow the leg
    # ---- the head: a round cranium and a long rounded snout in ONE soft union (one clean outline)
    C1 = Vector((0.42 * d * k, -0.34 * k, h + 2.5 * k))
    fwd = Vector((0.45 * d, -1.0, -0.1)).normalized()     # yawed ~24 deg to the toe side: the muzzle
                                                          # shows in profile from the front
    side = fwd.cross(Z).normalized()
    up = side.cross(fwd).normalized()
    Ri = Matrix((side, fwd, up))                     # world -> head frame (x across, y along, z up)
    cr = Vector((0.7, 0.6, 0.56)) * k
    C2 = C1 + fwd * (0.74 * k) - up * (0.16 * k)
    sr = Vector((0.47, 0.6, 0.37)) * k

    def ell(p, cen, rad):
        q = Ri @ (p - cen)
        return (math.sqrt((q.x / rad.x) ** 2 + (q.y / rad.y) ** 2 + (q.z / rad.z) ** 2) - 1.0) * min(rad)

    def F(p):
        return _smin(ell(p, C1, cr), ell(p, C2, sr), 0.2 * k)

    hc = C1.lerp(C2, 0.42)
    head = _star_mesh(F, hc, c.body, seg=28, thetas=[math.pi * i / 14 for i in range(1, 14)], rmax=2.5 * k,
                      step=0.02, name="head")
    out.append(head)
    hray = _bvh([head])
    # ---- the googly eyes move from the leg to the top of the head, tilted to look forward and up
    tilt = math.radians(26.0)
    yaw = math.atan2(fwd.x, -fwd.y)
    R = Matrix.Rotation(yaw, 4, "Z") @ Matrix.Rotation(-tilt, 4, "X")
    e_dir = (R.to_3x3() @ Vector((0.0, -1.0, 0.0))).normalized()
    O = Vector((0.0, sum(e[1] for e in c.eyes) / len(c.eyes), c.ey))
    hit = hray(C1, e_dir)
    Q = (hit[0] if hit else C1 + e_dir * cr.y) - e_dir * 0.035
    _move_face(c, Matrix.Translation(Q) @ R @ Matrix.Translation(-O))
    # nostrils on top of the snout tip
    for s_ in (-1, 1):
        hit = hray(C2, fwd * 0.78 + up * 0.55 + side * (s_ * 0.33))
        if hit:
            p, n = hit
            out.append(_ellipsoid(nostril, p - n * 0.008, (0.055, 0.07, 0.03), _frame(n, fwd), seg=8, rings=3,
                                  outline=False, name="nostril"))
    # a wide smile round the front of the snout, curling up at the corners; pink cheeks behind them
    pts, nrms = [], []
    for i in range(9):
        b = _lerp(-1.0, 1.0, i / 8)
        a = b * math.radians(78)
        dv = fwd * math.cos(a) + side * math.sin(a) - up * (0.52 - 0.3 * b * b)
        hit = hray(C2 - fwd * 0.05, dv)
        if hit:
            pts.append(hit[0] + hit[1] * 0.012)
            nrms.append(hit[1])
    if len(pts) > 3:
        for s_, end, nxt in ((-1, 0, 1), (1, -1, -2)):
            p0, n0 = pts[end], nrms[end]
            curl = p0 + (p0 - pts[nxt]).normalized() * 0.06 + up * 0.09
            hit = hray(curl + n0 * 0.4, -n0)
            if hit:
                q = (hit[0] + hit[1] * 0.012, hit[1])
                if s_ < 0:
                    pts.insert(0, q[0])
                    nrms.insert(0, q[1])
                else:
                    pts.append(q[0])
                    nrms.append(q[1])
        out.append(S._ink(pts, nrms, 0.034, samples=1, taper=0.5, name="smile"))
        mid = C1.lerp(C2, 0.5)
        for p0 in (pts[0], pts[-1]):
            hit = hray(mid, (p0 + up * 0.1 - fwd * 0.12) - mid)
            if hit:
                p, n = hit
                out.append(_ellipsoid(cheek, p + n * 0.004, (0.1, 0.075, 0.014), _frame(n, up), seg=10, rings=3,
                                      outline=False, name="cheek"))
    # ---- the neck: a curve that turns in 3D, so it is never a straight column from any side (its
    # centre line, seen from every azimuth, strays >= 0.6 from the straight line rim -> head). Out of
    # the opening it bows back (+Y) and out over the heel, swings across to the toe side up high,
    # then comes forward into the back of the head. Thick at the sock (the opening's dark lip still
    # shows round it), thin under the big head.
    path = [(0.0, 0.0, h - 0.5), (0.0, 0.0, h + 0.02), (0.0, 0.16 * k, h + 0.42 * k),
            (-0.32 * d * k, 0.4 * k, h + 0.92 * k), (-0.12 * d * k, 0.56 * k, h + 1.42 * k),
            (0.5 * d * k, 0.45 * k, h + 1.87 * k), (0.5 * d * k, -0.1 * k, h + 2.2 * k)]
    radii = [c.open_r - 0.12, c.open_r - 0.14, 0.45 * k, 0.4 * k, 0.36 * k, 0.32 * k, 0.29 * k]
    neck = _sweep(path, radii, c.body, seg=16, samples=3, cap0=0.0, cap1=0.0, name="neck")
    out.append(neck)
    nray = _bvh([neck])
    P = S._catmull([Vector(p) for p in path], 12)
    spine = _arc(P)
    run = sum((b - a).length for a, b in zip(P, P[1:]))          # length of the neck's centre line
    throat = (fwd - up * 0.8).normalized()                        # the belly's direction under the jaw

    def belly_dir(s):
        _p, T = spine(s)
        f = Vector((0.0, -1.0, -0.55)).normalized().lerp(throat, _smooth(min(max((s - 0.45) / 0.45, 0.0), 1.0)))
        f = f - T * f.dot(T)
        return f.normalized(), T

    def neck_surf(phi, s):
        p0, _T = spine(s)
        bd, T = belly_dir(s)
        dv = bd * math.cos(phi) + T.cross(bd) * math.sin(phi)
        hit = nray(p0, dv)
        if hit is None:
            return p0 + dv * 0.4 * k, dv
        return hit
    # the visible run of the neck: from just over the sock's lip to just under the jaw
    ss = [i / 200 for i in range(201)]
    s_lo = next(s for s in ss if spine(s)[0].z > h + 0.12)
    s_hi = max(s for s in ss if F(neck_surf(0.0, s)[0]) > 0.1 * k)
    # ---- belly: ONE continuous mint strip down the throat, about half the neck's width, made of five
    # soft segments (a thin darker-mint crease and a slight waist between them, rounded ends); a thin
    # skin lifted off the neck without ink, so it reads as the serpent's belly, not stuck-on bands
    sb0, sb1 = s_lo + 0.02, s_hi - 0.01
    n_sc, per, nu = 5, 9, 6
    nv = n_sc * per
    crease = hexcol(f"{tid}_belly_crease", "#74CDBE")    # only a shade darker: one strip at a glance

    def half_w(f):
        w = _lerp(0.5, 0.42, f)
        e = min(f, 1.0 - f) / 0.07                     # round off both ends
        if e < 1.0:
            w *= math.sqrt(max(1.0 - (1.0 - e) ** 2, 0.0))
        g = (f * n_sc) % 1.0                            # a soft waist at every crease
        return max(w * (0.86 + 0.14 * math.sin(math.pi * g) ** 0.5), 0.03)

    bm = bmesh.new()
    grid, nrm = [], []
    for kk in range(nv + 1):
        f = kk / nv
        sv_ = _lerp(sb0, sb1, f)
        w = half_w(f)
        row, nrow = [], []
        for i in range(nu + 1):
            pnt, nn = neck_surf(_lerp(-w, w, i / nu), sv_)
            row.append(bm.verts.new(pnt + nn * 0.016))
            nrow.append(nn)
        grid.append(row)
        nrm.append(nrow)
    pals = []
    for kk in range(nv):
        is_crease = kk % per == per - 1 and kk < nv - 1
        for i in range(nu):
            fc = bm.faces.new((grid[kk][i], grid[kk][i + 1], grid[kk + 1][i + 1], grid[kk + 1][i]))
            fc.normal_update()
            if fc.normal.dot(nrm[kk][i] + nrm[kk + 1][i + 1]) < 0:
                fc.normal_flip()
            pals.append(crease if is_crease else acc)
    out.append(_piece(bm, pals, "belly", outline=False, smooth=True))
    # ---- ONE centred row of fins down the back: the head, the neck, the sock (a zig-zag crest)
    def dorsal(s):
        bd, T = belly_dir(s)
        return -bd, T

    fins = []
    for a, L_, H_ in ((0.72, 0.56, 0.75), (1.14, 0.58, 0.78), (1.55, 0.54, 0.7)):
        hit = hray(C1, up * math.cos(a) - fwd * math.sin(a))      # a: from the crown toward the back
        if hit:
            along = -(up * math.sin(a) + fwd * math.cos(a))
            fins.append(_fin(acc, hit[0], hit[1], along, L_ * k, H_ * k, 0.075 * k, name="crest"))
    # ear frills: fans standing out sideways and up from the back of the cranium, their flat faces
    # toward the front and the back, so from behind the head shows a fan of fins, not a knob
    for s_ in (-1, 1):
        hit = hray(C1, side * s_ - fwd * 0.3 + up * 0.25)
        if hit:
            n = (side * s_ + up * 0.25).normalized()
            along = up - side * (0.25 * s_)
            fins.append(_fin(acc, hit[0], n, along, 0.66 * k, 0.44 * k, 0.075 * k, lean=0.28, name="ear"))
    # neck fins, evenly spaced by arc length from under the back of the head to the lip
    s_top = max(s for s in ss if F(spine(s)[0] + dorsal(s)[0] * radii[-1]) > 0.12 * k)
    n_neck = max(2, int((s_top - s_lo) * run / (0.3 * k)) + 1)
    for i in range(n_neck):
        s = _lerp(s_top, s_lo + 0.03, i / (n_neck - 1))
        dv, T = dorsal(s)
        hit = nray(spine(s)[0], dv)
        if not hit:
            continue
        f = 1.0 - 0.32 * i / (n_neck - 1)
        fins.append(_fin(acc, hit[0], hit[1], -T, 0.62 * k * f, 0.62 * k * f, 0.07 * k, name="spine"))
    # the crest carries on down the sock's back to the heel, as big as the lowest neck fin
    f = 0.68
    for z, a in ((h - 0.3 * k, math.pi), (h - 0.76 * k, math.pi + 0.12 * d), (h - 1.22 * k, math.pi + 0.3 * d)):
        p, n = c.surface(a, z)
        fins.append(_fin(acc, p, n, -Z, 0.62 * k * f, 0.62 * k * f, 0.07 * k, name="spine"))
    out += fins
    # the clothespin grips the top of the head / neck: above everything within 0.25 of the axis
    ray = _bvh([head, neck] + fins)
    tops = []
    for j in range(9):
        r = 0.0 if j == 0 else 0.25
        a = TAU * j / 8
        hit = ray((r * math.cos(a), r * math.sin(a), h + 8.0), (0.0, 0.0, -1.0))
        if hit:
            tops.append(hit[0].z)
    if tops:
        c.pin_z = max(tops) + 0.08
    # ---- suds: a low foam puddle round the foot that trails off behind the heel; its edge is a
    # rolled, bulging bead of foam (no straight side wall, 44 rim points), lumpy in plan ...
    tip = Vector(c.toe_tip)
    hx = c.heel_c.x - c.heel_radii.x * math.cos(math.radians(35)) * d
    cx = (hx + tip.x) / 2
    pa, pb = abs(tip.x - hx) / 2 + 0.4, 1.0
    u = Vector((-0.8 * d, 0.6, 0.0)).normalized()      # the trail: behind the heel
    un = Vector((u.y, -u.x, 0.0))
    tc, ta, tb = u * 2.12 * k, 1.55 * k, 0.75 * k

    def pud(x, y):
        e1 = (math.hypot((x - cx) / pa, y / pb) - 1.0) * pb
        q = Vector((x, y, 0.0)) - tc
        e2 = (math.hypot(q.dot(u) / ta, q.dot(un) / tb) - 1.0) * tb
        return _smin(e1, e2, 0.45)

    pc = Vector((_lerp(cx, tc.x, 0.45), _lerp(0.0, tc.y, 0.45), 0.0))
    seg = 44
    rim = []
    for j in range(seg):
        ph = TAU * j / seg
        dv = Vector((math.cos(ph), math.sin(ph), 0.0))
        lo, r = 0.0, 0.05
        while r < 6.0 and pud(pc.x + dv.x * r, pc.y + dv.y * r) < 0:
            lo, r = r, r + 0.05
        hi = r
        for _i in range(14):
            mid = (lo + hi) / 2
            if pud(pc.x + dv.x * mid, pc.y + dv.y * mid) < 0:
                lo = mid
            else:
                hi = mid
        rim.append(dv * (lo + 0.07 * math.sin(9 * ph + 0.4) + 0.04 * math.sin(14 * ph + 1.3)))
    lump = [0.5 + 0.5 * math.sin(9 * TAU * j / seg + 0.4) for j in range(seg)]    # 1 on a lump, 0 between
    # (radius factor, z): the floor rim, the bulge of the rolled bead, its top, then the flat foam
    prof = [(1.0, 0.0), (1.04, 0.06), (1.0, 0.13), (0.9, 0.17), (0.75, 0.2), (0.0, 0.21)]
    bm = bmesh.new()
    rings_v = []
    for f_, z_ in prof:
        if f_ == 0.0:
            rings_v.append(bm.verts.new((pc.x, pc.y, z_)))
            continue
        ring = []
        for j, rv in enumerate(rim):
            zz = z_ * (1.0 + 0.35 * (lump[j] - 0.4)) if 0.0 < z_ < 0.2 else z_     # the bead rises on each lump
            # rings are pushed out / pulled in by a fixed margin (not scaled), so the bead is the
            # same size all round and the thin trail stays round
            L_ = rv.length + (f_ - 1.0) * 1.6 if f_ >= 1.0 else max(rv.length - (1.0 - f_) * 1.6, rv.length * 0.15)
            q = rv.normalized() * L_
            ring.append(bm.verts.new((pc.x + q.x, pc.y + q.y, zz)))
        rings_v.append(ring)
    pals = []
    bm.faces.new(list(reversed(rings_v[0])))
    pals.append(foam2)
    for i_ in range(len(rings_v) - 1):
        A, B = rings_v[i_], rings_v[i_ + 1]
        for j in range(seg):
            j2 = (j + 1) % seg
            if isinstance(B, list):
                bm.faces.new((A[j], A[j2], B[j2], B[j]))
            else:
                bm.faces.new((A[j], A[j2], B))
            pals.append(foam2 if i_ == 0 else foam)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    out.append(_piece(bm, pals, "puddle"))
    # ... a few fat foam clumps sitting on the bead, so the edge is bumpy, not a cut board
    for i in range(5):
        j = int(seg * (i + 0.15 + 0.3 * _rnd(i, 41)) / 5) % seg
        rv = rim[j]
        r = 0.19 + 0.06 * _rnd(i, 42)
        q = pc + rv.normalized() * (rv.length - 0.1)
        out.append(_blob(foam, (q.x, q.y, 0.15), None, (r, r, 0.8 * r), seg=8, rings=2, cut=-0.25,
                         lump=0.1, seed=i, name="foam"))
    # ... two tall humps of the serpent's body (daylight under each arch) and the tip of its tail,
    # every end well inside the puddle and above the floor
    # each arch is a half ellipse (span / sin 1.4 wide, hgt tall) whose curvature radius at the top,
    # span^2 / hgt, stays 1.3x the tube radius - a tighter arch folds its inside over itself and
    # its ink hull pokes through as a dark tick
    for t, span, hgt, rr in ((1.5, 0.56, 1.0, 0.24), (2.55, 0.48, 0.84, 0.2)):
        b0 = u * (t * k)
        base = -0.05
        # (each leg's foot - 0.9 rr round - must stand inside the puddle outline)
        while span > 0.2 and max(pud(*(b0 + u * (s_ * span * k)).xy) for s_ in (-1, 1)) > -(0.9 * rr * k + 0.03):
            span *= 0.92
        hgt = min(hgt, (span / math.sin(1.4)) ** 2 / (1.3 * rr))
        apts, arad = [], []
        for i in range(7):
            a = _lerp(-1.4, 1.4, i / 6)
            apts.append(b0 + u * (span * k * math.sin(a) / math.sin(1.4)) + Z * (base + hgt * k * math.cos(a)))
            arad.append(rr * k * (0.88 + 0.12 * math.cos(a)))

        def under(s_, ph, cen):
            # the inside of the arch is a mint belly strip (the sweep's frame starts with its normal
            # along u, i.e. toward the inside of the arch, and keeps it there: the arch is planar)
            return acc if math.cos(TAU * ph) > 0.4 else c.body
        out.append(_sweep(apts, arad, c.body, seg=10, samples=2, cap0=0.0, cap1=0.0, up=u, pal_fn=under, name="hump"))
        top_p = apts[3] + Z * (arad[3] * 0.92)
        out.append(_fin(acc, top_p, Z, u, 0.4 * k * rr / 0.25, 0.4 * k * rr / 0.25, 0.075 * k, name="humpfin"))
    # the tail tip: rises out of the foam beyond the second hump (its root 0.4 inside the trail's end,
    # just above the floor) and flicks up and out
    t0 = u * (3.12 * k)
    tpts = [t0 + Z * 0.02, t0 + u * 0.12 * k + Z * 0.34, t0 + u * 0.32 * k + Z * 0.68, t0 + u * 0.58 * k + Z * 0.86,
            t0 + u * 0.8 * k + Z * 0.76]
    out.append(_sweep(tpts, [0.2 * k, 0.18 * k, 0.14 * k, 0.09 * k, 0.05 * k], c.body, seg=10, samples=2,
                      cap0=0.0, cap1=1.0, name="tail"))
    # ... and three soap bubbles (pale cyan / lilac, a white glint up front) - suds, not snowballs
    bub_c = hexcol(f"{tid}_bubble", "#BEE9F4")
    bub_l = hexcol(f"{tid}_bubble_lilac", "#D6CBF3")
    bubbles = [(Vector((cx + 0.86 * (pa - 0.25) * d, -0.62 * (pb - 0.15), 0.0)), 0.27, bub_c),
               (Vector((cx - 0.78 * (pa - 0.25) * d, -0.72 * (pb - 0.15), 0.0)), 0.21, bub_l),
               (u * 1.95 * k + un * 0.52, 0.19, bub_c)]
    for q, r, pal_ in bubbles:
        ctr = Vector((q.x, q.y, 0.2 + 0.72 * r))
        out.append(K.sphere(pal_, r, Matrix.Translation(ctr), seg=9, rings=5, name="bubble"))
        g = ctr + Vector((-0.3 * d, -0.55, 0.55)).normalized() * (r * 0.8)
        out.append(_ellipsoid(K.WHITE, g, (r * 0.24, r * 0.24, r * 0.15), _frame((g - ctr), Z), seg=5, rings=3,
                              outline=False, name="glint"))
    return out


# ------------------------------------------------------------------ Static Shockini
_BOLT = [(-0.02, 0.5), (-0.3, -0.05), (-0.05, -0.05), (-0.2, -0.5), (0.3, 0.13), (0.05, 0.13), (0.24, 0.5)]
_SPARK = [(math.cos(TAU * k / 8 + math.pi / 2) * (0.5 if k % 2 == 0 else 0.17),
           math.sin(TAU * k / 8 + math.pi / 2) * (0.5 if k % 2 == 0 else 0.17)) for k in range(8)]


def _kinked(base, dirv, L, r0, pal, kinks=1, amp=0.05, seed=0.0, width=(0.06, 0.042), name="hair"):
    """A hair standing on end: a strand from base along dirv tapering to a point, with `kinks`
    small sharp zig-zag kinks; its own thin, tapering ink hull."""
    dirv = Vector(dirv).normalized()
    side = Z.cross(dirv)
    if side.length < 1e-3:
        side = Vector((1.0, 0.0, 0.0))
    side.normalize()
    side = side * math.cos(seed) + dirv.cross(side) * math.sin(seed)
    n = kinks + 2
    pts, radii = [], []
    for i in range(n):
        t = i / (n - 1)
        off = 0.0 if i in (0, n - 1) else amp * (1 if i % 2 else -1)
        pts.append(Vector(base) + dirv * (L * t) + side * off)
        radii.append(r0 * (1.0 - 0.62 * t))
    return _strand(pts, radii, pal, width=[_lerp(width[0], width[1], i / (n - 1)) for i in range(n)], seg=5, samples=1,
                   cap1=1.6, name=name)


def feat_shockini(c):
    """Static! Hair standing on end: a full dandelion burst of thin, sharply zig-zagged pale-yellow
    strands with their own thin ink line, fanning out of a fuzzy tuft in the opening; a few kinked
    single hairs standing out of the sides and back of the leg; a blue zig-zag stripe; four chunky
    blue lightning bolts (two facing front, two facing back) at different heights, kept clear of the
    face, and sparks. Shocked face: tiny pinpoint pupils in wide eyes, high arched brows and a tall
    open oval mouth."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    bolt = hexcol(f"{tid}_bolt", "#5CC8FF")
    hair = hexcol(f"{tid}_hair", "#FFF27A")
    mouth_in = hexcol(f"{tid}_mouth", "#8C1D2C")
    tongue = hexcol(f"{tid}_tongue", "#F27A93")
    out = []
    # a fuzzy tuft filling the opening, the hair roots
    out.append(_blob(c.body, (0.0, 0.0, h - 0.12), None, (c.open_r + 0.03, c.open_r + 0.03, 0.3), seg=14, rings=4,
                     cut=0.0, lump=0.07, seed=5, name="tuft"))
    # dandelion burst: strands radiating from a point in the tuft, all round and up; elevations
    # >= 20 deg so the low ones clear the lip
    cen = Vector((0.0, 0.0, h - 0.02))
    rows = [(12, 8, 1.2, 0.0), (35, 7, 1.15, 0.45), (58, 5, 1.02, 0.2), (82, 2, 0.9, 0.25)]
    k = 0
    for el, cnt, L, ph in rows:
        e = math.radians(el)
        for j in range(cnt):
            az = TAU * (j + ph) / cnt + 0.2 * (_rnd(k, 1) - 0.5)
            dv = Vector((math.sin(az) * math.cos(e), -math.cos(az) * math.cos(e), math.sin(e)))
            ln = L * (0.85 + 0.3 * _rnd(k, 2))
            out += _kinked(cen + dv * 0.32, dv, ln, 0.064, hair, kinks=2, amp=0.12, seed=math.pi * (k % 2),
                           width=(0.042, 0.036), name="hairburst")
            k += 1
    # a few kinked single hairs standing out of the sides and back of the leg (static), away from
    # the face and clear of the bolts
    for a, z in ((-2.0, c.ey + 0.05), (2.05, c.ey - 0.35), (math.pi - 0.35, c.ey - 0.05), (math.pi + 0.5, c.instep_z + 1.0)):
        p, n = c.surface(a * d, z)
        out += _kinked(p - n * 0.03, n + Vector((0.0, 0.0, 0.25)), 0.4, 0.05, hair, kinks=2, amp=0.06, seed=0.5,
                       name="statichair")
    # zig-zag stripe round the leg (ink band under a blue band)
    zc, amp, teeth = c.instep_z + 0.36, 0.11, 9
    for g, lf, pal in ((0.035, 0.004, K.BLACK), (0.0, 0.016, bolt)):
        hw = 0.09 + g

        def grid(u, v, hw=hw):
            kk = u * teeth * 2
            tri = 1.0 - 2.0 * abs((kk % 2.0) - 1.0)
            return TAU * u, zc + amp * tri + _lerp(-hw, hw, v)
        out.append(_conform(c, teeth * 2, 1, grid, lf, 0.02, pal, wrap=True, name="zigzag"))
    # lightning bolts: two out at the front sides (turned to the viewer, below the eyes, clear of
    # the face from every side), two on the back sides
    # (each side has one high and one low bolt, a front one and a back one: they never line up
    # behind each other in the front or 3/4 views)
    for a, z, R, spin, sc, face in ((-1.72, c.ey - 0.12, 1.6, -0.3, 1.3, -1), (1.7, c.instep_z + 0.42, 1.6, 0.35, 1.2, -1),
                                    (math.pi - 0.95, c.cuff_z - 0.05, 1.4, 0.3, 1.1, 1),
                                    (math.pi + 1.25, c.instep_z + 0.3, 1.45, -0.25, 1.15, 1)):
        a *= d
        out_dir = Vector((math.sin(a), -math.cos(a), 0.0))
        nrm = (out_dir * 0.45 + Vector((0.0, face * 1.0, 0.0))).normalized()
        rot = _frame(nrm, Z) @ Matrix.Rotation(spin * d, 4, "Z")
        poly = [(x * d * face * -1, y) for x, y in _BOLT]
        mat = Matrix.Translation(out_dir * R + Vector((0.0, 0.0, z))) @ rot @ Matrix.Diagonal(Vector((sc, sc, 1.0, 1.0)))
        out.append(_prism(poly, 0.16, mat, bolt, bevel=0.035, segs=1, name="bolt"))
    for a, z, R, sc in ((-0.75 * d, h + 1.35, 1.45, 0.4), (1.05 * d, h + 1.5, 1.35, 0.34), (math.pi + 0.5 * d, h + 1.2, 1.4, 0.38)):
        out_dir = Vector((math.sin(a), -math.cos(a), 0.0))
        nrm = (out_dir * 0.5 + Vector((0.0, -1.0 if abs(a) < 2 else 1.0, 0.0))).normalized()
        mat = Matrix.Translation(out_dir * R + Vector((0.0, 0.0, z))) @ _frame(nrm, Z) @ Matrix.Diagonal(Vector((sc, sc, 1.0, 1.0)))
        out.append(_prism(_SPARK, 0.1, mat, bolt, bevel=0.02, segs=1, name="spark"))
    # shocked eyes: the big googly pupils are covered by fresh whites with tiny centred pupils
    for i in range(len(c.eyes)):
        T, wrap = c.eye_mats[i], c.eye_wrap[i]
        look = Vector((0.0, 0.06, 1.0)).normalized()
        parts = [S._cap(K.WHITE, (0.0, 0.0, 1.0), math.radians(62), T, lift=0.036, seg=18, rings=3, name="eyecover"),
                 S._cap(K.BLACK, look, math.radians(17), T, lift=0.047, seg=14, rings=2, name="pinpupil"),
                 S._cap(K.WHITE, (look + Vector((-0.12, 0.14, 0.0))).normalized(), math.radians(5), T, lift=0.058, seg=8, rings=1,
                        name="pinglint")]
        S._wrap_pieces(parts, wrap)
        out += parts
    # high arched brows, well above the eye rims
    for i in range(len(c.eyes)):
        e = Vector(c.eyes[i])
        si = 1.0 if e.x > 0 else -1.0
        top = e.z + c.eye_rim_r
        out.append(_ink_line(c, [(e.x + si * 0.22, top + 0.05), (e.x + si * 0.06, top + 0.16), (e.x - si * 0.12, top + 0.15),
                                 (e.x - si * 0.21, top + 0.08)], radius=0.048, taper=0.45, samples=2, name="brow"))
    # tall open oval mouth: dark red with an ink rim, a little tongue at the bottom
    mz = c.mouth_z - 0.11
    hw, hh = 0.14, 0.21

    def oval(g):
        w_, h_ = hw + g, hh + g
        f = lambda u: h_ * max(1 - (u / w_) ** 2, 0.0) ** 0.5  # noqa: E731
        return -w_, w_, (lambda u: mz + f(u)), (lambda u: mz - f(u))
    out += S._inked(c.face_point, oval, mouth_in, border=0.036, lift=0.026, n=11, name="mouth")

    def tng(g):
        w_ = 0.095 + g
        return (-w_, w_, (lambda u: mz - hh * 0.55 + 0.04 * max(1 - (u / w_) ** 2, 0.0) ** 0.5),
                (lambda u: mz - hh * 0.98 * max(1 - (u / (hw * 1.05)) ** 2, 0.0) ** 0.5))
    x0, x1, tp_, bt_ = tng(0.0)
    out.append(S._plate(c.face_point, [_lerp(x0, x1, i / 8) for i in range(9)], tp_, bt_, 0.038, tongue, name="mtongue"))
    return out


# ------------------------------------------------------------------ Lintlord
def _scallop_rim(R, nb, seed, stretch, amp=0.09):
    """The outline of a lint drift: an irregular soft blob (a middle oval and three big puffs in one
    smooth union, stretched `stretch` x sideways) whose rim is a row of nb round scallops of equal
    length (amp deep). Sampled 4 times per scallop, at its cusp, its shoulders and its top, so the
    mesh rings follow the scallops exactly. -> (angles, radii, scallop heights 0.12..1 (cusp ..
    top), the blob's radius without the scallops), 4 * nb samples, the biggest radius about R."""
    circles = [(0.0, 0.0, 0.62)]
    ph = _rnd(seed, 1) * TAU
    for i in range(3):
        a = ph + TAU * (i + 0.3 * (_rnd(seed, i + 2) - 0.5)) / 3
        circles.append((0.4 * math.cos(a), 0.32 * math.sin(a), 0.34 + 0.1 * _rnd(seed, i + 21)))

    def sdf(x, y):
        x /= stretch
        v = math.hypot(x - circles[0][0], y - circles[0][1]) - circles[0][2]
        for cx, cy, r in circles[1:]:
            v = _smin(v, math.hypot(x - cx, y - cy) - r, 0.18)
        return v

    def reach(th):
        dx, dy = math.cos(th), math.sin(th)
        lo, r = 0.0, 0.02
        while r < 3.0 and sdf(dx * r, dy * r) < 0:
            lo, r = r, r + 0.02
        hi = r
        for _i in range(12):
            mid = (lo + hi) / 2
            if sdf(dx * mid, dy * mid) < 0:
                lo = mid
            else:
                hi = mid
        return (lo + hi) / 2

    n = 144
    ths = [TAU * j / n for j in range(n + 1)]
    rc = [reach(th) for th in ths[:-1]]
    rc.append(rc[0])
    pts = [Vector((math.cos(t) * r, math.sin(t) * r)) for t, r in zip(ths, rc)]
    acc = [0.0]
    for p0, p1 in zip(pts, pts[1:]):
        acc.append(acc[-1] + (p1 - p0).length)
    tot = acc[-1]
    prof = (0.12, 0.8, 1.0, 0.8)                      # cusp (rounded a little), shoulder, top, shoulder
    out_t, out_r, out_h, out_b = [], [], [], []
    k = 0
    off = _rnd(seed, 9)
    for i in range(nb):
        for q, hgt in enumerate(prof):
            target = ((i + q / 4 + off) / nb % 1.0) * tot
            while not (acc[k] <= target <= acc[k + 1]):
                k = (k + 1) % n
            f = (target - acc[k]) / max(acc[k + 1] - acc[k], 1e-9)
            th = _lerp(ths[k], ths[k + 1], f)
            b = _lerp(rc[k], rc[k + 1], f)
            out_t.append(th)
            out_r.append(b + amp * hgt)
            out_h.append(hgt)
            out_b.append(b + amp * 0.6)
    order = sorted(range(len(out_t)), key=lambda j: out_t[j])
    s = R / max(out_r)
    return ([out_t[j] for j in order], [out_r[j] * s for j in order], [out_h[j] for j in order],
            [out_b[j] * s for j in order])


def _cyc(ths, vals, a):
    """Value at angle a interpolated from samples (ths ascending in 0..TAU, cyclic)."""
    a %= TAU
    n = len(ths)
    for j in range(n):
        t0, t1 = ths[j], ths[(j + 1) % n] + (TAU if j == n - 1 else 0.0)
        aa = a + (TAU if a < t0 else 0.0)
        if t0 <= aa <= t1:
            return _lerp(vals[j], vals[(j + 1) % n], (aa - t0) / max(t1 - t0, 1e-9))
    return vals[0]


def _stitch(bm, A, ta, B, tb):
    """Triangles joining two closed rings of different vertex counts (vertices in ascending angle
    order, angles ta / tb in 0..TAU starting near 0) by zipping along the angles."""
    n, m = len(A), len(B)
    i = j = 0
    while i < n or j < m:
        an = ta[(i + 1) % n] + (TAU if i + 1 >= n else 0.0)
        bn = tb[(j + 1) % m] + (TAU if j + 1 >= m else 0.0)
        if i < n and (j >= m or an <= bn):
            bm.faces.new((A[i % n], A[(i + 1) % n], B[j % m]))
            i += 1
        else:
            bm.faces.new((A[i % n], B[(j + 1) % m], B[j % m]))
            j += 1


# (rho, height / thick): a pillow with a rolled edge - the rim tucked just under the surface, a
# quick rise into a round bead, then a broad soft dome (so a drift seen edge-on is a rounded bump)
_PAD_PROF = [(1.0, 0.0), (0.97, 0.35), (0.9, 0.65), (0.75, 0.88), (0.5, 0.97), (0.25, 0.995), (0.0, 1.0)]


def _pad_height(rho):
    """Height of a lint drift's cushion (a fraction of `thick`) at rho (0 = middle, 1 = rim)."""
    for (ra, ha), (rb, hb) in zip(_PAD_PROF, _PAD_PROF[1:]):
        if rb <= rho <= ra:
            return _lerp(hb, ha, (rho - rb) / max(ra - rb, 1e-6))
    return 1.0 if rho < 1.0 else 0.0


def _ribbon(pts, nrms, width, pal, name="strand"):
    """A flat, one-sided brush stroke lying on a surface (normals nrms): widest in the middle,
    tapering to points at both ends. No hull."""
    bm = bmesh.new()
    m = len(pts)
    lv, rv = [], []
    for i in range(m):
        t = (pts[min(i + 1, m - 1)] - pts[max(i - 1, 0)]).normalized()
        sd = nrms[i].cross(t).normalized()
        w = width * max(math.sin(math.pi * i / (m - 1)), 0.12) ** 0.6
        lv.append(bm.verts.new(pts[i] + sd * w))
        rv.append(bm.verts.new(pts[i] - sd * w))
    for i in range(m - 1):
        f = bm.faces.new((lv[i], rv[i], rv[i + 1], lv[i + 1]))
        f.normal_update()
        if f.normal.dot(nrms[i]) < 0:
            f.normal_flip()
    return _piece(bm, pal, name, outline=False, smooth=False)


def _lint_pad(surf, R, seed, pal, strand_pal, thick=0.24, nb=8, stretch=1.2, sink=0.015, ink=0.02, amp=0.11,
              wob=0.45, n_in=16, n_strands=3, name="lintpad"):
    """A soft lint drift hugging a surface: surf(x, y) -> (point, normal) maps local patch coordinates
    (world units round 0, 0) onto the body. A pillow `thick` high in the middle (_PAD_PROF: a rolled
    bead round the edge, a broad dome on top) whose outline is an irregular soft blob rimmed with nb
    round scallops (_scallop_rim); the bead rises and dips with the scallops (each scallop's top
    `wob` higher than its cusp), so seen edge-on the drift is a bumpy cloud, not a slab. The rim is
    tucked just under the surface and the shell is closed underneath (a fan to a point inside the
    body), so it has ONE clean hull; the inner rings (no scallops) use only n_in vertices. A thin
    flat ink line runs round the scalloped rim (the hull can't draw one where the rim meets the
    body) and a few short, roughly parallel darker strand lines are drawn on top, like the fibres
    the sheet draws in Sockrates' beard. -> [pad, ink, strands]"""
    ths, rim, sc, base = _scallop_rim(R, nb, seed, stretch, amp)
    uni = [TAU * j / n_in for j in range(n_in)]
    bm = bmesh.new()
    p0, n0 = surf(0.0, 0.0)
    top = bm.verts.new(p0 + n0 * thick)
    rings = []
    for rho, hf in _PAD_PROF[:-1]:
        if rho > 0.7:                                # the scalloped bead
            fade = 1.0 if rho > 0.8 else 0.5
            ring = [(th, r * rho, 1.0 + wob * fade * (s_ - 0.65)) for th, r, s_ in zip(ths, rim, sc)]
        else:                                        # the dome: plain blob outline, fewer vertices
            ring = [(a, _cyc(ths, base, a) * rho, 1.0) for a in uni]
        vs = []
        for th, r, md in ring:
            p, n = surf(r * math.cos(th), r * math.sin(th))
            vs.append(bm.verts.new(p + n * (hf * thick * md if hf > 0 else -sink)))
        rings.append((vs, [t for t, _r, _m in ring]))
    bot = bm.verts.new(p0 - n0 * (0.1 + R * 0.5))
    for (A, ta), (B, tb) in zip(rings, rings[1:]):
        _stitch(bm, A, ta, B, tb)
    inner = rings[-1][0]
    for j in range(len(inner)):
        bm.faces.new((top, inner[j], inner[(j + 1) % len(inner)]))
    rimv = rings[0][0]
    for j in range(len(rimv)):
        bm.faces.new((bot, rimv[(j + 1) % len(rimv)], rimv[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    out = [_piece(bm, pal, name, outline=True, smooth=True)]
    bm = bmesh.new()
    inn, outr = [], []
    for th, r in zip(ths, rim):
        for lst, rr in ((inn, r - 0.015), (outr, r + ink)):
            p, n = surf(rr * math.cos(th), rr * math.sin(th))
            lst.append(bm.verts.new(p + n * 0.012))
    seg = len(ths)
    for j in range(seg):
        j2 = (j + 1) % seg
        bm.faces.new((inn[j], outr[j], outr[j2], inn[j2]))
    bm.normal_update()
    bm.faces.ensure_lookup_table()
    if bm.faces[0].normal.dot(n0) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    out.append(_piece(bm, K.BLACK, name + "_ink", outline=False, smooth=True))
    # strand lines: a few short, gently curved fibres running the same way across the cushion
    rmin = min(rim)
    flow = 0.35 + 0.5 * (_rnd(seed, 60) - 0.5)
    fd = Vector((math.cos(flow), math.sin(flow)))
    fn = Vector((-fd.y, fd.x))
    for i in range(n_strands):
        # staggered along the flow as well as across it, so they read as loose fibres, not ribs
        c0 = (fn * (rmin * 0.42 * (i - (n_strands - 1) / 2))
              + fd * (rmin * (0.3 * (i % 2) - 0.15 + 0.15 * _rnd(seed, i + 70))))
        L = rmin * (0.36 + 0.16 * _rnd(seed, i + 90))
        pts, nrms = [], []
        for t in range(5):
            f = t / 4 - 0.5
            q = c0 + fd * (L * f) + fn * (0.12 * L * (1.0 - 4.0 * f * f))
            rho = min(q.length / max(rmin, 1e-6), 1.0)
            p, n = surf(q.x, q.y)
            pts.append(p + n * (thick * _pad_height(rho) + 0.014))
            nrms.append(n)
        out.append(_ribbon(pts, nrms, 0.022, strand_pal, name=name + "_strand"))
    return out


def _wisp(p0, out_dir, bend_dir, length=0.5, r0=0.11, A=0.45, curl=1.15, pal=None, width=0.022, n=7, name="wisp"):
    """A soft lint wisp: a strand from p0 whose chord runs along out_dir, fat at the base (r0) and
    tapering to a fine tip, waving in an S in the plane of out_dir and bend_dir (its heading starts
    A radians toward bend_dir, swings A the other way and back) and curling over toward bend_dir in
    its last third (`curl` radians more). A thin ink line (`width`) like _strand, from a cheap
    hidden core."""
    v = Vector(out_dir).normalized()
    t = Vector(bend_dir)
    t = (t - v * t.dot(v)).normalized()
    pts = [Vector(p0) - v * 0.06]
    pos = Vector(p0)
    pts.append(pos.copy())
    ds = length / (n - 1)
    for i in range(1, n):
        s = (i - 0.5) / (n - 1)
        th = A * math.cos(TAU * s) + curl * max(0.0, (s - 0.62) / 0.38) ** 2
        pos = pos + (v * math.cos(th) + t * math.sin(th)) * ds
        pts.append(pos.copy())
    m = len(pts)
    rr = [r0 * (1.0 - 0.87 * (max(i - 1, 0) / (m - 2)) ** 1.5) for i in range(m)]
    inner = [max(r - (HULL - width), 0.004) for r in rr]
    return [_sweep(pts, rr, pal, seg=5, samples=1, cap0=0.0, cap1=1.0, cap_rings=2, outline=False, name=name),
            _sweep(pts, inner, pal, seg=4, samples=1, cap0=0.0, cap1=1.0, cap_rings=2, outline=True, name=name + "_core")]


def feat_lintlord(c):
    """A gold crown (ball-tipped points, red and blue gems on the band, a red velvet cap filling it)
    on a fluffy lint ruff round the rim; the sock wrapped in a few big soft lint drifts - light warm
    lavender-grey pillows (a clear step above the grey sock, like the sheet's fluffy grey beard)
    with rolled, bumpy cloud edges (round scallops that also rise and dip, so a drift seen edge-on
    is a soft bumpy cloud) and a few darker strand lines on top, each one closed shell with one
    clean ink line. They wrap round the leg's edges so the outline goes cloud-soft from every side:
    one from the toe-side edge round to the back, one from the heel-side edge round the back and up
    into the ruff, one over the heel toward the back of the ankle and one over the toe and up the
    instep; the face and the band under the mouth stay grey sock. Fat, soft S-curled lint wisps
    stick out of both ends of the ruff, the back of the ruff and the side drifts (leaning back and
    out, below the crown band); smug half-lids over the googly eyes."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    gold = hexcol(f"{tid}_gold", "#F5C842")
    gold2 = hexcol(f"{tid}_gold_dark", "#D19A2C")
    velvet = hexcol(f"{tid}_velvet", "#B32E45")
    ruby = hexcol(f"{tid}_ruby", "#E8334F")
    sapph = hexcol(f"{tid}_sapphire", "#3A7BF0")
    lint = hexcol(f"{tid}_lint", "#D4CFDC")          # light warm lavender-grey
    lint2 = hexcol(f"{tid}_lint_warm", "#C9C3D2")    # a touch deeper
    strand = hexcol(f"{tid}_lint_strand", "#9F99AC")  # strand lines on the fluff
    out = []
    tilt = Matrix.Rotation(math.radians(-7) * d, 4, "Y")     # a rakish tilt toward the heel
    base = Matrix.Translation((0.0, 0.0, h - 0.16)) @ tilt
    # ---- the lint ruff under the crown band: ONE ring of round puffs (a round cross-section),
    # alternate puffs set higher and lower, so its outline is scalloped from every side
    nl, per = 12, 4
    m = nl * per
    pts, radii = [], []
    for j in range(m):
        a = TAU * j / m
        lob = (0.5 + 0.5 * math.cos(nl * a + 0.4)) ** 0.8
        r = c.top_r + 0.06 + 0.03 * lob
        pts.append(base @ Vector((math.sin(a) * r, -math.cos(a) * r, -0.05 + 0.06 * math.cos(nl * a * 0.5 + 0.2) * lob)))
        radii.append(0.18 * (0.5 + 0.5 * lob))
    out.append(_sweep(pts, radii, lint, seg=6, closed=True, flat=1.0, up=Z, name="ruff"))
    # ---- crown: a thick ring whose top edge zig-zags into five points
    npts, per = 5, 8
    cols = npts * per
    R0, th = c.top_r + 0.07, 0.07
    z0, zv, zp = 0.0, 0.42, 0.95
    bm = bmesh.new()
    rows = []
    for j in range(cols):
        a = TAU * j / cols                          # a point straight over the face
        f = (j % per) / per
        tri = abs(1.0 - 2.0 * f)                    # 1 at a point, 0 midway
        top = zv + (zp - zv) * tri ** 1.6
        fl = 0.06 * (top - z0)                           # flares out toward the top
        rows.append((a, [(z0, R0), (zv * 0.5, R0 + 0.015), (top, R0 + fl)]))
    outer, inner = [], []
    for a, col in rows:
        ca, sa = math.sin(a), -math.cos(a)
        outer.append([bm.verts.new(base @ Vector((ca * rr, sa * rr, rz))) for rz, rr in col])
        inner.append([bm.verts.new(base @ Vector((ca * (rr - th), sa * (rr - th), rz))) for rz, rr in col])
    pals = []
    for j in range(cols):
        j2 = (j + 1) % cols
        for r in range(2):
            bm.faces.new((outer[j][r], outer[j2][r], outer[j2][r + 1], outer[j][r + 1]))
            pals.append(gold)
            bm.faces.new((inner[j][r + 1], inner[j2][r + 1], inner[j2][r], inner[j][r]))
            pals.append(gold2)
        bm.faces.new((outer[j][2], outer[j2][2], inner[j2][2], inner[j][2]))
        pals.append(gold)
        bm.faces.new((inner[j][0], inner[j2][0], outer[j2][0], outer[j][0]))
        pals.append(gold2)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    out.append(_piece(bm, pals, "crown", outline=True, smooth=False))
    # band trim: a rounded rim along the bottom edge
    out.append(K.torus(gold2, R0 - th / 2 + 0.01, 0.06, base @ Matrix.Translation((0.0, 0.0, 0.02)), seg=20, mseg=4, name="crownrim"))
    for k in range(npts):
        a = TAU * k / npts
        top = base @ Vector((math.sin(a) * (R0 + 0.06 * zp), -math.cos(a) * (R0 + 0.06 * zp), zp + 0.05))
        out.append(K.sphere(gold, 0.1, Matrix.Translation(top), seg=8, rings=3, name="crownball"))
        # the gem's widest ring stands just proud of the band (band radius here ~R0 + 0.018), so its
        # ink line hugs its edge instead of showing through the band as a separate ring
        gz = zv * 0.62
        gr = R0 + 0.015 + 0.042 * (gz - zv * 0.5) / (zp - zv * 0.5) + 0.032
        gp = base @ Vector((math.sin(a) * gr, -math.cos(a) * gr, gz))
        n = (base.to_3x3() @ Vector((math.sin(a), -math.cos(a), 0.0))).normalized()
        out.append(_ellipsoid(ruby if k % 2 == 0 else sapph, gp, (0.1, 0.13, 0.05), _frame(n, base.to_3x3() @ Z),
                              seg=8, rings=3, name="gem"))
    # velvet cap filling the crown, topped by a little gold ball
    vel = [(0.0, -0.05), (R0 - th - 0.005, -0.05), (R0 - th - 0.02, zv * 0.5), (R0 * 0.8, zv + 0.12), (R0 * 0.45, zv + 0.3),
           (0.0, zv + 0.36)]
    out.append(_lathe(vel, velvet, seg=20, mat=base, name="velvet"))
    out.append(K.sphere(gold, 0.09, base @ Matrix.Translation((0.0, 0.0, zv + 0.42)), seg=8, rings=4, name="capball"))
    # the crown closes the opening: the clothespin clips the cap ball on top
    c.pin_z = (base @ Vector((0.0, 0.0, zv + 0.51))).z + 0.1

    # ---- big soft lint drifts wrapping the sock (the face and the band under the mouth stay grey)
    def on_leg(a0, z0):
        r0 = c.radius_at(z0, a0)
        return lambda x, y: c.surface(a0 + x / r0, z0 + y)

    def on_body(hit, o):
        """Patch coordinates round a surface point of the heel / toe / foot: points of its tangent
        plane projected onto the body by rays cast out from o, a point inside that part."""
        p0, n0 = Vector(hit[0]), Vector(hit[1]).normalized()
        e1 = Z.cross(n0)
        e1 = e1.normalized() if e1.length > 1e-4 else Vector((1.0, 0.0, 0.0))
        e2 = n0.cross(e1).normalized()
        o = Vector(o)

        def surf(x, y):
            q = p0 + e1 * x + e2 * y
            h_ = c.ray(o, q - o)
            return h_ if h_ else (q, n0)
        return surf

    eye_lo = c.ey - c.eye_rim_r                      # bottom of the eyes' ink rims
    drifts = []
    for a, z, R, st, seed, pal in (
            (2.35, min(c.mouth_z - 0.2, eye_lo - 0.45), 1.05, 1.2, 3, lint),   # toe-side edge -> back, mid-leg
            (-2.25, eye_lo + 0.25, 0.9, 1.0, 4, lint2)):                       # heel-side edge -> back, up into the ruff
        drifts.append((on_leg(a * d, z), R, st, seed, pal))
    if c.d:
        hc = Vector(c.heel_c)
        hit = c.ray(hc, Vector((-0.75 * d, 0.5, 0.3)))      # over the heel, toward the back of the ankle
        if hit:
            drifts.append((on_body(hit, hc), 0.9, 1.25, 20, lint))
        tc = Vector(c.toe_c)
        hit = c.ray(tc, Vector(c.toe_dir) * 0.5 + Vector((0.0, -0.45, 0.8)))   # over the toe and up the instep
        if hit:
            drifts.append((on_body(hit, tc), 1.0, 1.3, 21, lint2))
    for surf, R, st, seed, pal in drifts:
        out += _lint_pad(surf, R, seed, pal, strand, stretch=st, name="lintpad")
    # ---- fat, soft lint wisps: out of both ends of the ruff (as the front view sees it) and its
    # back, aimed outward and a little down, and off the outer edges of the two side drifts; none
    # passes in front of the crown band from the front, the sides or the back
    tips = []
    # each one leans back (round the leg toward the back) as well as out, so it sticks out past the
    # outline from the front, the side and the back alike and no main view looks down its length
    # (end-on a wisp reads as a spike); not mirrored pairs, so the back never shows a 'moustache'
    def lean(a, out, back, upw):
        rdir = Vector((math.sin(a), -math.cos(a), 0.0))
        tb = Vector((math.cos(a), math.sin(a), 0.0))         # round the leg ...
        tb = tb if tb.y >= 0.0 else -tb                      # ... toward the back (+Y)
        return (rdir * out + tb * back + Z * upw).normalized(), rdir

    for a, ln, dz, upw in ((1.72, 0.56, -0.08, -0.5), (-1.7, 0.48, -0.12, -0.85), (math.pi - 0.55, 0.5, -0.1, -0.6)):
        # locks flicking out and down off the ruff, the tip curling up
        aa = a * d
        v, rdir = lean(aa, 0.72, 0.45, upw)
        p = base @ Vector((math.sin(aa) * (c.top_r + 0.14), -math.cos(aa) * (c.top_r + 0.14), dz))
        tips.append((p, v, Z, ln))
    for a, z in ((1.9, min(c.mouth_z - 0.2, eye_lo - 0.45) + 0.45), (-1.9, eye_lo - 0.15)):
        # tufts rising out of the side drifts, curling over outward
        p, n = c.surface(a * d, z)
        v, _r = lean(a * d, 0.6, 0.55, 0.6)
        tips.append((p + n * 0.12, v, -Z, 0.52))
    for i, (p, v, bend, ln) in enumerate(tips):
        out += _wisp(p, v, bend, length=ln, pal=lint, name="wisp")
    # smug half-lids (their ink line stays on the front of the eyeball)
    out += _lids(c, c.body, math.radians(96), math.radians(72), lift=0.03, line_r=0.04, clip=0.4, name="lid")
    return out


# ------------------------------------------------------------------ Sockzillionaire
_BILL_W, _BILL_H, _BILL_T = 0.7, 0.34, 0.04


def _bill(mat, cash, cash2, cash3):
    """A banknote: a thin rounded slab with a pale oval portrait window and two darker corner dots
    on both faces (flat discs through the slab)."""
    out = [K.rounded_box(cash, (_BILL_W, _BILL_T, _BILL_H), mat, bevel=0.03, segments=1, name="bill")]
    rx = Matrix.Rotation(math.pi / 2, 4, "X")
    out.append(K.cylinder(cash2, 1.0, 1.0, mat @ rx @ Matrix.Diagonal(Vector((0.11, 0.11, _BILL_T + 0.014, 1.0))), seg=10,
                          outline=False, name="billoval"))
    for sx in (-1, 1):
        out.append(K.cylinder(cash3, 1.0, 1.0, mat @ Matrix.Translation((sx * 0.24, 0.0, 0.0)) @ rx
                              @ Matrix.Diagonal(Vector((0.055, 0.075, _BILL_T + 0.012, 1.0))), seg=5, outline=False,
                              name="billdot"))
    return out


def feat_zillionaire(c):
    """A tall black top hat with a green band (hollow underneath, so the sock's rim sits inside
    it), a curly black moustache with a smirk under it, a gold monocle and chain on the toe-side
    eye, and a fountain of green bills bursting out of the hat top and tumbling down one side."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    hat = hexcol(f"{tid}_hat", "#26222E")
    hat2 = hexcol(f"{tid}_hat_top", "#3A3446")
    hat_in = hexcol(f"{tid}_hat_inside", "#17141D")
    band = hexcol(f"{tid}_band", "#3C9A48")
    tash = hexcol(f"{tid}_tash", "#2A2230")
    gold = hexcol(f"{tid}_gold", "#FFD24A")
    lens = hexcol(f"{tid}_lens", "#BFE6F5")
    cash = hexcol(f"{tid}_cash", "#5DBE5A")
    cash2 = hexcol(f"{tid}_cash_light", "#BEEBAA")
    cash3 = hexcol(f"{tid}_cash_dark", "#3C8E3E")
    out = []
    # top hat, hollow underneath: the sock's rim sits up inside the crown, so the tilted hat never
    # lets the rim poke through its brim
    # (the hollow gets no ink hull: an inward hull would poke out of the leg as a sawtooth)
    tilt = Matrix.Translation((0.0, 0.0, h - 0.12)) @ Matrix.Rotation(math.radians(-8) * d, 4, "Y")
    rc = c.top_r + 0.1
    rb, wall, ceil = rc + 0.38, 0.035, 0.3
    out.append(_lathe([(0.0, ceil), (rc - wall, ceil), (rc - wall, -0.03)], hat_in, seg=26, mat=tilt, outline=False,
                      name="hatinside"))
    prof = [(rc - wall, -0.03), (rb - 0.08, -0.02), (rb, 0.03), (rb + 0.01, 0.1),
            (rb - 0.05, 0.12), (rc + 0.02, 0.08), (rc, 0.18), (rc + 0.04, 1.2), (rc + 0.05, 1.28), (rc, 1.33), (0.0, 1.34)]
    out.append(_lathe(prof, hat, seg=26, mat=tilt, pal_fn=lambda k, j, cen: hat2 if k >= len(prof) - 3 else hat,
                      name="tophat"))
    bprof = [(rc + 0.025, 0.12), (rc + 0.035, 0.42)]
    out.append(_lathe([(rc - 0.02, 0.12)] + bprof + [(rc - 0.02, 0.42)], band, seg=26, mat=tilt, name="hatband"))
    # bill tucked in the band on the heel side
    bp = tilt @ Vector((-d * (rc + 0.03), 0.06, 0.4))
    out += _bill(Matrix.Translation(bp) @ Matrix.Rotation(-d * 0.35, 4, "Y") @ Matrix.Rotation(d * math.pi / 2 + 0.25 * d, 4, "Z")
                 @ Matrix.Rotation(math.pi / 2 - 0.2, 4, "Y") @ Matrix.Diagonal(Vector((0.8, 1.0, 0.8, 1.0))), cash, cash2, cash3)
    # moustache: a flat inked handlebar drawn on the face (two fat lobes meeting at a point in the
    # middle, drooping a little, tapering out) with solid curls turned up at both ends; it sits
    # well under the eye rims, a band of gold in between
    mz = c.ey - c.eye_rim_r - 0.28
    L = 0.42
    ths = [(0.0, 0.07), (0.05, 0.13), (0.12, 0.17), (0.22, 0.15), (0.32, 0.105), (0.42, 0.065)]
    cls = [(0.0, 0.035), (0.12, -0.005), (0.25, -0.02), (0.36, 0.0), (0.42, 0.03)]

    def interp(tab, a_):
        a_ = min(max(a_, tab[0][0]), tab[-1][0])
        for (a0, v0), (a1, v1) in zip(tab, tab[1:]):
            if a_ <= a1:
                return _lerp(v0, v1, _smooth((a_ - a0) / (a1 - a0)))
        return tab[-1][1]

    def tash_shape(g):
        def top(u):
            return mz + interp(cls, abs(u)) + interp(ths, abs(u)) * 0.55 + g

        def bot(u):
            return mz + interp(cls, abs(u)) - interp(ths, abs(u)) * 0.45 - g
        return -L - g, L + g, top, bot
    out += S._inked(c.face_point, tash_shape, tash, border=0.025, lift=0.024, n=17, name="tash")
    for s_ in (-1, 1):
        curl = [(s_ * 0.36, mz + 0.01), (s_ * 0.47, mz + 0.02), (s_ * 0.55, mz + 0.08), (s_ * 0.55, mz + 0.16),
                (s_ * 0.48, mz + 0.195), (s_ * 0.43, mz + 0.15)]
        hits = [c.face_point(x, z, 0.03) for x, z in curl]
        out.append(S._ink([p for p, _n in hits], [n for _p, n in hits], 0.05, flat=0.6, samples=3, taper=0.55,
                          pal=tash, name="tashcurl"))
    # a smirk under it, rising toward the toe
    sz = mz - 0.22
    out.append(_ink_line(c, [(d * x, sz + z) for x, z in ((-0.15, 0.0), (-0.05, -0.025), (0.06, -0.015), (0.15, 0.03))],
                         radius=0.032, name="smirk"))
    # monocle on the toe-side eye, with a chain down to the side of the leg
    e = 1 if d > 0 else 0
    ctr, n = Vector(c.eyes[e]), Vector(c.eye_n[e]).normalized()
    xa = Vector((0, 0, 1)).cross(n).normalized()
    ya = n.cross(xa).normalized()
    pc = ctr + n * (c.eye_r * c.eye_flat + 0.04)
    R = c.eye_rim_r * 1.0
    rot = Matrix((xa, ya, n)).transposed().to_4x4()
    out.append(K.torus(gold, R, 0.06, Matrix.Translation(pc) @ rot, seg=24, mseg=6, name="monocle"))
    gl = pc + n * 0.02 + (xa * -0.1 + ya * 0.12)
    out.append(K.sphere(lens, 1.0, Matrix.Translation(gl) @ rot @ Matrix.Rotation(-0.7, 4, "Z") @ Matrix.Diagonal(Vector((0.035, 0.1, 0.01, 1))),
                        seg=8, rings=5, outline=False, name="glint"))
    knob = pc + d * xa * (R + 0.05) - ya * 0.12
    out.append(K.sphere(gold, 0.06, Matrix.Translation(knob), seg=10, rings=6, name="knob"))
    a_end = d * math.radians(80)
    z_end = c.ey - 1.05
    pts = [knob]
    for f in (0.3, 0.6, 0.85, 1.0):
        a = _lerp(math.atan2(knob.x, -knob.y), a_end, f ** 1.5)
        z = _lerp(knob.z - 0.05, z_end, f)
        p, nn = c.surface(a, z, 0.05 + 0.08 * math.sin(f * math.pi))
        pts.append(p)
    out.append(_sweep(pts, [0.028] * len(pts), gold, seg=6, samples=3, name="chain"))
    p, nn = c.surface(a_end, z_end, 0.02)
    out.append(K.torus(gold, 0.07, 0.025, Matrix.Translation(p) @ _frame(nn), seg=12, mseg=5, name="chainloop"))
    # cash spray: a fountain of bills bursting up out of the top of the hat, arcing over toward the
    # toe side and tumbling down past the brim (plus two strays to the heel side and the back),
    # spread in depth and each turned its own way, so it reads from the front, side, back and top
    top = (tilt @ Vector((0.0, 0.0, 1.34))).z
    bills = [  # (x toward the toe, y (- = front), z above the hat top, size, yaw, pitch, roll) - angles in degrees
        (0.05, -0.12, 0.3, 0.72, 15, 35, 10), (-0.35, 0.3, 0.62, 0.82, -40, -20, 25), (0.5, -0.38, 0.88, 0.95, 50, 15, -20),
        (1.0, 0.32, 0.78, 1.0, -55, 40, 30), (1.42, -0.42, 0.3, 1.05, 30, -35, -40), (1.78, 0.22, -0.4, 1.05, -20, 55, 15),
        (1.62, -0.62, -1.05, 1.0, 60, -15, 50), (1.95, 0.42, -1.7, 0.95, -35, 25, -60), (-1.15, -0.32, -0.1, 0.8, -50, 20, -35),
        (-0.55, 0.78, 0.25, 0.8, 35, -45, 20),
    ]
    for x, y, z, sc, yaw, pitch, roll in bills:
        mat = (Matrix.Translation((x * d, y, top + z)) @ Matrix.Rotation(math.radians(yaw) * d, 4, "Z")
               @ Matrix.Rotation(math.radians(pitch), 4, "X") @ Matrix.Rotation(math.radians(roll) * d, 4, "Y")
               @ Matrix.Diagonal(Vector((sc * 1.1, 1.0, sc * 1.1, 1.0))))
        out += _bill(mat, cash, cash2, cash3)
    return out


# ------------------------------------------------------------------ The Lost Sock
def feat_lost(c):
    """A big ghostly question mark floating above in a cool pale lavender-blue (a round tube + ball
    with a lighter core stripe, a soft halo ring round the dot and a thin ink line; turned ~40 deg
    and its hook bent back in depth, so it reads from the side too), a tear rolling down the cheek,
    a darned patch with cross stitches, and a frayed hole with a loose thread on the back."""
    tid, h = c.tid, c.h
    ghost = hexcol(f"{tid}_ghost", "#C9D2F5")
    ghost_core = hexcol(f"{tid}_ghost_core", "#EEF1FF")
    halo = hexcol(f"{tid}_halo", "#DCE2FA")
    tear = hexcol(f"{tid}_tear", "#8FD6FF")
    patch = hexcol(f"{tid}_patch", "#6577C2")
    stitch = hexcol(f"{tid}_stitch", "#E3E9FF")
    out = []
    z0 = h + 0.8
    rot = (Matrix.Translation((0.0, 0.0, z0)) @ Matrix.Rotation(math.radians(10), 4, "Y") @ Matrix.Rotation(math.radians(-40), 4, "Z")
           @ Matrix.Diagonal(Vector((1.2, 1.2, 1.2, 1.0))))
    # (x, depth, z): the hook's curl swings back in depth, the stem comes forward again
    hook = [(-0.36, 0.0, 0.72), (-0.3, 0.1, 0.98), (-0.05, 0.2, 1.12), (0.25, 0.22, 1.06), (0.4, 0.15, 0.84), (0.33, 0.06, 0.6),
            (0.12, 0.0, 0.45), (0.02, -0.02, 0.3), (0.0, -0.02, 0.14)]
    pts = [rot @ Vector(q) for q in hook]
    # pale and cool with a thin ink line (half the usual weight): spectral, not a solid toy
    qr = [0.14, 0.165, 0.175, 0.175, 0.175, 0.175, 0.165, 0.16, 0.155]
    out += _thin_inked(lambda rr, _p, ol: _sweep(pts, rr, ghost, seg=9, samples=3, outline=ol, name="question"), qr, 0.028)
    nf = (rot.to_3x3() @ Vector((0.0, -1.0, 0.0))).normalized()          # the face of the '?'
    sp = [pts[i] + nf * (qr[i] - 0.004) for i in range(1, 7)]
    out.append(S._ink(sp, [nf] * len(sp), 0.05, samples=3, taper=0.35, pal=ghost_core, name="qcore"))
    dot = rot @ Vector((0.0, -0.02, -0.2))
    out += _thin_inked(lambda rr, _p, ol: K.sphere(ghost, rr[0], Matrix.Translation(dot), seg=12, rings=7, outline=ol,
                                                   name="qdot"), [0.19], 0.028)
    out.append(K.sphere(ghost_core, 0.07, Matrix.Translation(dot + nf * 0.15 + rot.to_3x3() @ Vector((-0.04, 0.0, 0.05))),
                        seg=8, rings=4, outline=False, name="qglint"))
    rq = rot.to_3x3().normalized().to_4x4() @ Matrix.Rotation(math.pi / 2, 4, "X")
    out.append(K.torus(halo, 0.33, 0.028, Matrix.Translation(dot) @ rq, seg=24, mseg=5, outline=False, name="qhalo"))
    # tear under the right eye: a drop shape on the cheek
    ex = c.eyes[1][0]
    p, n = c.face_point(ex + 0.06, c.ey - c.eye_rim_r - 0.2, 0.035)
    fr = _frame(n, Z)
    out.append(_ellipsoid(tear, p, (0.09, 0.12, 0.05), fr, seg=12, rings=7, name="tear"))
    out.append(K.cylinder(tear, 0.075, 0.15, Matrix.Translation(p + fr.to_3x3() @ Vector((0.0, 0.12, 0.0)))
                          @ fr @ Matrix.Rotation(-math.pi / 2, 4, "X"), seg=10, radius2=0.005, name="teartip"))
    gl = p + fr.to_3x3() @ Vector((-0.03, 0.03, 0.05))
    out.append(K.sphere(K.WHITE, 0.025, Matrix.Translation(gl), seg=6, rings=4, outline=False, name="tearglint"))
    # a worn hole on the back with a loose thread curling out of it
    ha, hz = math.pi - 0.35, _lerp(c.instep_z, c.cuff_z, 0.45)
    out.append(_blob_decal(c, ha, hz, lambda th: 0.23 * (1.0 + 0.16 * math.sin(4 * th + 0.5) + 0.1 * math.sin(7 * th)),
                           0.004, 0.012, patch, rings=2, seg=14, name="fray"))
    out.append(_blob_decal(c, ha, hz, lambda th: 0.16 * (1.0 + 0.2 * math.sin(3 * th + 0.5) + 0.1 * math.sin(5 * th)),
                           0.016, 0.012, K.BLACK, rings=2, seg=12, name="hole"))
    r_h = c.radius_at(hz, ha)
    th_pts = []
    for k, (da, dz, lf) in enumerate(((0.0, -0.08, 0.02), (0.06, -0.2, 0.06), (0.02, -0.33, 0.12), (-0.09, -0.36, 0.17),
                                      (-0.12, -0.27, 0.2))):
        th_pts.append(c.surface(ha + da / r_h, hz + dz, lf)[0])
    out.append(_sweep(th_pts, [0.03] * 5, stitch, seg=6, samples=3, cap0=1.0, cap1=1.0, name="thread"))
    # darned patch on the right side of the leg
    pa, pz = 0.55, _lerp(c.bulb_c.z, c.instep_z, 0.3) if c.side == "S" else c.instep_z + 0.4
    out += _leg_patch(c, pa, pz, 0.5, 0.48, 0.004, 0.02, patch, border=0.035, spin=0.12)
    r = c.radius_at(pz, pa)
    for k in range(8):
        f = (k + 0.5) / 8
        side = k // 2
        u = (f * 4) % 1
        loc = {0: (_lerp(-0.2, 0.2, u), 0.2), 1: (0.21, _lerp(0.2, -0.2, u)), 2: (_lerp(0.2, -0.2, u), -0.2),
               3: (-0.21, _lerp(-0.2, 0.2, u))}[side]
        cs, sn = math.cos(0.12), math.sin(0.12)
        x, y = loc[0] * cs - loc[1] * sn, loc[0] * sn + loc[1] * cs
        for sgn in (-1, 1):
            q0 = c.surface(pa + (x - 0.04) / r, pz + y - 0.04 * sgn, 0.045)
            q1 = c.surface(pa + (x + 0.04) / r, pz + y + 0.04 * sgn, 0.045)
            out.append(S._ink([q0[0], q1[0]], [q0[1], q1[1]], 0.016, samples=1, pal=stitch, name="stitch"))
    return out


# ------------------------------------------------------------------ Sock Puppet Supreme
def feat_puppet(c):
    """A huge open puppet mouth on the front (deep red inside, a row of white teeth on top, a
    pink tongue lolling over the fat lower lip, lips standing proud of the face), sewn-on button
    eyes, and a mop of yellow yarn strands flopping out of the opening over the rim."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    inside = hexcol(f"{tid}_mouth", "#B3192F")
    tongue = hexcol(f"{tid}_tongue", "#FF7C98")
    lip = hexcol(f"{tid}_lip", "#E04A2A")
    yarn = hexcol(f"{tid}_yarn", "#FFC531")
    yarn2 = hexcol(f"{tid}_yarn_dark", "#F29A1E")
    out = []
    fp = c.face_point
    top_z = c.ey - c.eye_rim_r - 0.08
    w, depth = 0.56, 0.78

    def top(u):
        return top_z - 0.06 * (1 - (u / w) ** 2)

    def bot(u):
        return top_z - depth * max(1 - (abs(u) / w) ** 2.4, 0.0) ** 0.55

    def shape(g):
        ww = w + g
        return (-ww, ww, (lambda u: top(u * w / ww) + g), (lambda u: bot(u * w / ww) - g))
    out += S._inked(fp, shape, inside, border=0.04, lift=0.02, n=15, name="mouthin")
    # tongue: a fat pink blob resting in the bottom of the mouth, hanging over the lower lip
    tz = top_z - depth * 0.82
    pts, nrms = [], []
    for x, z, lf in ((-0.17 + 0.04 * d, tz + 0.03, 0.06), (0.06 * d, tz - 0.04, 0.1), (0.21 + 0.04 * d, tz + 0.03, 0.06)):
        p, n = fp(x, z, lf)
        pts.append(p)
        nrms.append(n)
    out.append(_sweep(pts, [0.13, 0.16, 0.13], tongue, seg=10, samples=3, flat=0.45, up=nrms[1], name="tongue"))
    p, n = fp(0.06 * d, tz - 0.03, 0.1 + 0.16 * 0.45 + 0.005)
    q, n2 = fp(0.06 * d, tz + 0.09, 0.08 + 0.13 * 0.45)
    out.append(S._ink([q, p], [n2, n], 0.022, samples=2, taper=0.5, name="crease"))
    # teeth: four rounded white teeth along the top
    for k in range(4):
        x = _lerp(-0.3, 0.3, k / 3)

        def tooth(g, x=x):
            tw = 0.088 + g
            z0 = top(x) + 0.01 + g
            return (x - tw, x + tw, (lambda u: z0), (lambda u: z0 - 0.18 - g - 0.025 * (1 - ((u - x) / tw) ** 2)))
        out += S._inked(fp, tooth, K.WHITE, border=0.024, lift=0.04, n=5, name="tooth")
    # lips: a fat roll round the mouth, standing out from the face
    loop = []
    nl = 28
    for k in range(nl):
        f = k / nl
        if f < 0.5:      # top edge left -> right
            u = _lerp(-w, w, f * 2)
            z = top(u) + 0.02
        else:            # bottom edge right -> left
            u = _lerp(w, -w, (f - 0.5) * 2)
            z = bot(u) - 0.02
        loop.append((u * 1.06, z))
    pts, radii = [], []
    for k, (x, z) in enumerate(loop):
        lower = k >= nl // 2
        r = 0.09 if lower else 0.07
        side = abs(x) / (w * 1.06)
        r *= _lerp(1.0, 0.75, side ** 3)
        p, n = fp(x, z, r * 0.55)
        pts.append(p)
        radii.append(r)
    out.append(_sweep(pts, radii, lip, seg=6, closed=True, name="lips"))
    # sewn-on button eyes: a flat dark-red button behind each googly eye, wider than its ink rim,
    # with two thread holes on the ring that shows below and outside the eye. The two buttons overlap at the
    # bridge, so they are ONE inked decal (the union of the two discs: no crossing hulls, no
    # z-fighting) with the toe-side button's edge drawn as an ink arc over the other.
    btn = hexcol(f"{tid}_button", "#9E2418")
    hole = hexcol(f"{tid}_hole", "#4A120C")
    ez = c.ey
    r_e = c.radius_at(ez)
    ex_arc = r_e * math.asin(min(abs(c.eyes[1][0]) / r_e, 0.99))     # eye centre, as arc length
    B = c.eye_rim_r + 0.09

    def union_r(th, g):
        cx = ex_arc
        return cx * abs(math.cos(th)) + math.sqrt(max((B + g) ** 2 - (cx * math.sin(th)) ** 2, 0.0))
    for g, lf, pal in ((0.03, 0.006, K.BLACK), (0.0, 0.02, btn)):
        out.append(_blob_decal(c, 0.0, ez, lambda th, g=g: union_r(th, g), lf, 0.012, pal, rings=2, seg=36, name="button"))
    s_top = d                                            # the toe-side button lies on top
    arc_pts, arc_n = [], []
    for k in range(9):
        ph = math.pi + math.radians(_lerp(-62.0, 62.0, k / 8))
        u, v = s_top * (ex_arc + B * math.cos(ph)), B * math.sin(ph)
        p, n = c.surface(u / r_e, ez + v, 0.038)
        arc_pts.append(p)
        arc_n.append(n)
    out.append(S._ink(arc_pts, arc_n, 0.022, samples=1, name="buttonedge"))
    for i in range(len(c.eyes)):
        sx = 1.0 if c.eyes[i][0] > 0 else -1.0
        for da in (36.0, 64.0):                      # lower-outer ring: the upper lip hides the bottom
            ph = math.radians(-90.0 + sx * da)
            rr = (c.eye_rim_r + B) / 2 + 0.005
            u, v = sx * ex_arc + rr * math.cos(ph), rr * math.sin(ph)
            p, n = c.surface(u / r_e, ez + v, 0.034)
            out.append(_ellipsoid(hole, p, (0.032, 0.032, 0.008), _frame(n, Z), seg=8, rings=3, outline=False,
                                  name="buttonhole"))
    # yarn hair: a mop of strands rooted all over the opening, arching up and flopping out over
    # the rim and down the sides and back to about the top of the eyes (short bangs over the face),
    # plus a few short curls standing up on top; two yarn yellows
    yarn = hexcol(f"{tid}_yarn", "#FFD23A")
    yarn2 = hexcol(f"{tid}_yarn_dark", "#E8B420")
    out.append(_lathe([(0.0, h - 0.2), (c.open_r + 0.02, h - 0.2), (c.open_r * 0.85, h + 0.05), (0.0, h + 0.12)],
                      yarn2, seg=16, name="yarnbase"))
    # (thin ink lines; the ends are staggered by up to +-0.25 at the back and sides, and three
    # strands flop much further down the back)
    N = 15
    eye_top = c.ey + c.eye_rim_r
    for k in range(N + 3):
        long_ = k >= N
        if long_:
            a = math.pi + (k - N - 1) * 0.42
            rr = c.open_r * 0.55
        else:
            rr = c.open_r * 0.8 * math.sqrt((k + 0.5) / N)
            a = k * 2.39996 + 0.3
        u = Vector((math.sin(a), -math.cos(a), 0.0))
        af = abs(math.atan2(math.sin(a), math.cos(a)))                 # 0 = over the face, pi = back
        back = _smooth((af - 0.5) / 0.9)
        z_end = _lerp(h - 0.3, eye_top - 0.02, back) + (0.08 + 0.42 * back) * (_rnd(k, 5) - 0.5)
        if long_:
            z_end = eye_top - 0.55 - 0.18 * (k - N)
        r_end = c.radius_at(z_end, a) + 0.07
        pts = [u * rr + Vector((0.0, 0.0, h - 0.08)),
               u * _lerp(rr, c.top_r, 0.55) + Vector((0.0, 0.0, h + 0.2 + 0.1 * _rnd(k, 6))),
               u * (c.top_r + 0.07) + Vector((0.0, 0.0, h + 0.02)),
               u * (r_end + 0.03) + Z.cross(u) * (0.05 * (_rnd(k, 7) - 0.5)) + Vector((0.0, 0.0, z_end))]
        if long_:   # a lazy S down the back
            pts.insert(3, u * (c.radius_at(_lerp(h, z_end, 0.5), a) + 0.1) + Z.cross(u) * (0.08 * (k - N - 1))
                       + Vector((0.0, 0.0, _lerp(h, z_end, 0.5))))
        out += _strand(pts, [0.074] * len(pts), yarn if k % 3 else yarn2, width=0.032, seg=4, samples=2, cap1=1.0,
                       name="yarn")
    for k in range(4):                                                  # curls standing up on top
        a = TAU * k / 4 + 0.6
        u = Vector((math.sin(a), -math.cos(a), 0.0))
        side = Z.cross(u)
        b0 = u * 0.18 + Vector((0.0, 0.0, h + 0.05))
        pts = [b0, b0 + u * 0.04 + Vector((0.0, 0.0, 0.3)), b0 + u * 0.2 + Vector((0.0, 0.0, 0.44)),
               b0 + u * 0.32 + side * 0.03 + Vector((0.0, 0.0, 0.3)), b0 + u * 0.2 + side * 0.06 + Vector((0.0, 0.0, 0.2))]
        out += _strand(pts, [0.06] * 5, yarn if k % 2 else yarn2, width=0.032, seg=4, samples=2, cap1=1.0, name="curl")
    return out


# Per-type tweaks merged over socks.SPECS (colours, mood, tall/short, ...). Never change `single`.
SPEC_OVERRIDES = {
    "Stinkolino": dict(mouth=False, cuff="dark"),
    "SockNess": dict(short=True, cuff="light", mouth=False, body="#2E9E98", dark="#1F7672", inner="#165956",
                     accent="#8FE0D0"),
    "Shockini": dict(mouth=False, mood="static", cuff="dark", cuff_h=0.2),
    "Lintlord": dict(cuff="body"),
    "Zillionaire": dict(mouth=False, cuff="dark",
                        # three bright gold-thread bands with deep edges, mid-leg (clear of the face)
                        stripes=[(1.95, 1.975, "Zillionaire_thread_edge"), (1.975, 2.065, "Zillionaire_thread"),
                                 (2.065, 2.09, "Zillionaire_thread_edge"), (2.15, 2.175, "Zillionaire_thread_edge"),
                                 (2.175, 2.265, "Zillionaire_thread"), (2.265, 2.29, "Zillionaire_thread_edge"),
                                 (2.35, 2.375, "Zillionaire_thread_edge"), (2.375, 2.465, "Zillionaire_thread"),
                                 (2.465, 2.49, "Zillionaire_thread_edge")]),
    "LostSock": dict(body="#2F3C7A", dark="#222B5C", inner="#151A3A", accent="#5A6AB0", cuff="dark"),
    "PuppetSupreme": dict(cuff="body"),
}

FEATURES = {
    "Stinkolino": feat_stinkolino,
    "SockNess": feat_sockness,
    "Shockini": feat_shockini,
    "Lintlord": feat_lintlord,
    "Zillionaire": feat_zillionaire,
    "LostSock": feat_lost,
    "PuppetSupreme": feat_puppet,
}
