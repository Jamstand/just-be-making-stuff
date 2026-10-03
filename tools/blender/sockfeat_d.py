"""
sockfeat_d.py - signature features for PolkaDottie, Pisolino, Bambino, Jingleo, Ninjolino, Sockbeard (the second wave).

Each feature builder takes the SockCtx `c` built by socks.py and returns a list of sockkit Pieces
added on top of the shared body (same rules as sockfeat_a/b/c.py: only SockCtx fields, colour names
prefixed with the type id, first registration wins). This module also keeps its types' rigging
(RIG: type id -> fn(R), the same per-type functions rigging.py has for the first wave), colour
retunes (SPEC_OVERRIDES) and texture hints (MATERIALS: colour-name pattern -> class, see
texturing.classify). None of these six has sheet art; each is designed in the sheet's style (the
shared body, googly eyes, ink outline hull, flat ink strokes, inked plates) around ONE big idea that
reads from any side and from far away:
  PolkaDottie  turquoise, scattered with white polka dots of three sizes (a Poisson scatter over the
               leg, the heel and the foot, cast onto the real surface, none on the face or the
               band); a big hot-pink satin bow on the front of the rim (two puffy lobes pinched at a
               plump knot, an ink fold line on each, two V-notched tails hanging over the band);
               three ink lashes flicking off each googly eye, pink blush, the happy smile.
  Pisolino     periwinkle pyjamas: thin white pinstripes that follow the knit (meridians: down the
               leg, round the heel onto the sole and over the instep onto the foot, converging at
               the toe; the face keeps a clean panel); a long navy nightcap over the rim (a rolled
               brim, the crown leaning to the heel side, the tail flopping out over the heel side and
               drooping well clear of the head) sprinkled with yellow stars and crescent moons, a fat
               lumpy white pompom on its tip; the shared 'tired' lids over a small sleepy 'o' mouth.
  Bambino      the short body in cream yellow with a ribbed baby-blue cuff: a baby-blue pacifier in
               the mouth (an oval shield with two vents, a knob, a ring handle tilted out in front),
               one brown curl springing out of the front of the opening (a short stem, then an '@'
               spiral turned mostly to the front, thin ink), rosy cheeks, and a yellow rubber duck
               printed (inked, orange beak, darker wing) on the toe side, facing the front.
  Jingleo      a red Christmas stocking with green heel and toe: a tall lumpy white fur roll (Santa's
               trim) over the rim and band, a holly sprig on its front (two spiky inked leaves with
               light veins, three glossy red berries), a gold jingle bell (equator band, a dark slot
               with round ends, the little ball showing) hooked on a loop sewn into the toe tip and
               swung forward off it (hanging straight it would touch the floor), two white
               snowflakes printed on the leg, rosy cheeks under the happy face.
  Ninjolino    an indigo sock in a darker hood: one shell round the top (over the dark band and lip,
               a mask down over the mouth, a pointed flap down the back) with an almond eye slit
               (inked edges; its top dips between the eyes, so with slanted lids the googly eyes
               glare); a red headband round the hood above the slit, knotted at the back with two
               long ribbon tails spreading out behind (a silver four-point star tucked in it on the
               toe side); three slanted grey bandage turns round the ankle; heel and toe in the
               hood's dark, like tabi. No mouth.
  Sockbeard    a sailor shirt (navy with four wide cream stripes under the face): a big black
               tricorn (a crown on a brim turned up into three walls - one facing the front - that
               meet in three points, gold trim along their tops) with a friendly white skull and
               crossbones on the front wall; a black eye patch over the heel-side eye on a strap that
               runs round the head and climbs across the forehead over the other eye (which gets a
               cocky raised brow); a gold hoop earring sticking out on the toe side; a big lopsided
               grin with a row of teeth and one gold tooth.
Decals sit >= 0.01 off what is under them (polka dots are raised until no facet of the body pokes
through); the pinstripes and snowflakes are flat ribbons, the duck and the holly flat inked
plates. Every sock body stays under 8,000 triangles.

Rig (RIG, per the brief): Bow (hat, child of Cuff); Cap1-3 (dangle 1, the nightcap's tail, Cap1
child of Cuff; the crown and brim ride Cuff); Paci (jaw, hinged behind the face like AnkleBiter's
Jaw) and Curl (spring, child of Cuff); Bell (dangle 1, child of Toe); Band1_1/1_2 and Band2_1/2_2
(dangles 1-2: the headband tails, 1 = the viewer's left, Band*_1 children of Leg4); Hat (the
tricorn, child of Cuff) and Earring (dangle 1, child of Leg4). Fat tubes that bend sharply (the
nightcap, the headband tails) are weighted by their own rings (_ArcChain), not by the nearest point
of their centre line, so the inside of the bend never folds. The hints (SWING, WOBBLE, PACI below)
are the largest angles tested clean with preview.py --pose on both halves.
"""
import bisect
import math
import random
import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, color, hexcol  # noqa: F401
import socks as S
import rigging
from sockfeat_a import _ribbon
from sockfeat_b import _fluff_roll, _puck, _shell
from sockfeat_c import _blob, _blob_decal, _bvh, _ellipsoid, _frame, _lids, _prism
from sockfeat_c import _strand as _strand_c, _sweep as _sweep_c

TAU = math.tau
Z = Vector((0.0, 0.0, 1.0))
_lerp, _smooth = S._lerp, S._smooth


# Rig hints (SockRigConfig): the largest values tested clean on L and R (preview.py --pose with extra
# test poses). Cap: 25 deg per bone outward / forward / back, but swung toward the head the pompom
# touches the cheek past ~10. Bell: 45 away from the toe, 30 back under it. Band tails: 30-35 every
# way. Earring: 35 every way. Curl: 30 every way, but past ~20 toward the heel side it sinks behind the rim.
# Paci: an 8 deg turn or a 0.12 slide still keeps the pacifier on the face (the brief asks ~5 / ~0.08).
SWING = {"Cap": 10, "Bell": 30, "Band": 30, "Earring": 35}
WOBBLE = {"Curl": 20}
PACI = {"turn": 6, "slide": 0.1}


# ------------------------------------------------------------------ geometry helpers
def _piece(bm, pals, name, outline=True, smooth=True):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pals, outline, smooth, name)


def _orient_tube(piece, path):
    """Turns every face of a tube built round the polyline `path` outward (majority vote over all
    faces, against the nearest path point). sockfeat_c._sweep decides from one face, which can pick
    the wrong turn of a tight spiral (Bambino's curl came out inside-out on the L sock)."""
    P = [Vector(q) for q in path]
    me = piece.mesh
    vote = 0.0
    for f in me.polygons:
        c0 = Vector(f.center)
        best, bd = P[0], 1e9
        for a, b in zip(P, P[1:]):
            ab = b - a
            t = max(0.0, min(1.0, (c0 - a).dot(ab) / max(ab.length_squared, 1e-12)))
            q = a + ab * t
            dd = (q - c0).length
            if dd < bd:
                best, bd = q, dd
        vote += f.area * (1.0 if f.normal.dot(c0 - best) > 0 else -1.0)
    if vote < 0:
        bm = bmesh.new()
        bm.from_mesh(me)
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
        bm.to_mesh(me)
        bm.free()
        me.update()
    return piece


def _sweep(pts, radii, pal, samples=4, **kw):
    """sockfeat_c._sweep with every face turned outward (see _orient_tube)."""
    pc = _sweep_c(pts, radii, pal, samples=samples, **kw)
    path = S._catmull([Vector(q) for q in pts], samples) if samples > 1 and len(pts) > 1 else [Vector(q) for q in pts]
    return _orient_tube(pc, path)


def _strand(pts, radii, pal, samples=1, **kw):
    """sockfeat_c._strand (a strand with a thin ink line) with every face turned outward."""
    pcs = _strand_c(pts, radii, pal, samples=samples, **kw)
    path = S._catmull([Vector(q) for q in pts], samples) if samples > 1 else [Vector(q) for q in pts]
    return [_orient_tube(pc, path) for pc in pcs]


def _tangents(n):
    """Two unit tangents for a surface normal n (t1 roughly horizontal, t2 roughly up)."""
    n = Vector(n).normalized()
    t1 = Z.cross(n)
    if t1.length < 1e-4:
        t1 = Vector((1.0, 0.0, 0.0))
    t1.normalize()
    return t1, n.cross(t1).normalized()


def _surface_disc(c, p, n, r, pal, lift=0.008, seg=12, rings=1, name="disc"):
    """A round printed spot lying on the body: every vertex is cast back onto the real surface
    (along -n from just above it) and lifted `lift`, so the spot hugs heel, toe and leg alike.
    One flat surface, no hull (a printed decal)."""
    t1, t2 = _tangents(n)
    bm = bmesh.new()

    def on(q):
        hit = c.ray(q + n * 0.25, -n)
        return (hit[0] + hit[1] * lift) if hit else (q + n * lift)

    ctr = bm.verts.new(on(p))
    rs = []
    for k in range(1, rings + 1):
        rho = r * k / rings
        rs.append([bm.verts.new(on(p + (t1 * math.cos(TAU * j / seg) + t2 * math.sin(TAU * j / seg)) * rho))
                   for j in range(seg)])
    for j in range(seg):
        j2 = (j + 1) % seg
        bm.faces.new((ctr, rs[0][j], rs[0][j2]))
        for a, b in zip(rs, rs[1:]):
            bm.faces.new((a[j], b[j], b[j2], a[j2]))
    # the body is faceted: where a flat facet edge bulges above the spot's own flat triangles, raise
    # the whole spot so it clears the body by at least lift / 2 everywhere (no poke-through)
    worst = lift
    for f in bm.faces:
        vs = [v.co for v in f.verts]
        for q in [sum(vs, Vector()) / len(vs)] + [(vs[k] + vs[(k + 1) % len(vs)]) / 2 for k in range(len(vs))]:
            hit = c.ray(q + n * 0.25, -n)
            if hit:
                worst = min(worst, (q - hit[0]).dot(n))
    if worst < lift / 2:
        for v in bm.verts:
            v.co += n * (lift / 2 - worst)
    bm.normal_update()
    for f in bm.faces:
        if f.normal.dot(n) < 0:
            f.normal_flip()
    return _piece(bm, pal, name, outline=False)


def _cheeks(c, pal, dx=0.17, dz=-0.42, size=(0.14, 0.09), name="cheek"):
    """Round blush discs on the face, below and outside each eye."""
    out = []
    for e in c.eyes:
        s = 1.0 if e[0] > 0 else -1.0
        p, n = c.face_point(e[0] + s * dx, c.ey + dz)
        out.append(_ellipsoid(pal, p + n * 0.004, (size[0], size[1], 0.014), _frame(n, Z), seg=12, rings=3,
                              outline=False, name=name))
    return out


def _lashes(c, angles=(18, 46, 74), length=0.15, radius=0.03, name="lash"):
    """Three ink flicks on the upper outer arc of each googly eye: each starts on the ink rim and
    flicks outward over the leg, curling up a little at its tip."""
    out = []
    for i, (e, n) in enumerate(zip(c.eyes, c.eye_n)):
        ctr = Vector(e)
        n = Vector(n).normalized()
        xa = Z.cross(n).normalized()
        ya = n.cross(xa).normalized()
        s = 1.0 if ctr.x > 0 else -1.0
        wrap = c.eye_wrap[i]
        R = c.eye_rim_r
        for a_deg in angles:
            a = math.radians(a_deg)
            dv = xa * (s * math.cos(a)) + ya * math.sin(a)
            curl = xa * (s * math.cos(a + 0.45)) + ya * math.sin(a + 0.45)
            root = wrap(ctr + dv * (R - 0.025) + n * 0.035)
            pts, nrms = [root], [n]
            for f, lf in ((0.5, 0.03), (1.0, 0.018)):
                q = ctr + dv * (R + length * f * 0.75) + curl * (length * f * 0.35)
                p, nn = c.face_point(q.x, q.z, lf)
                pts.append(p)
                nrms.append(nn)
            out.append(S._ink(pts, nrms, radius, seg=5, samples=2, taper=0.3, name=name))
    return out


# ------------------------------------------------------------------ Polka Dottie
def _bow(pal, pal2, knot_pos, tilt, roll, size=1.0):
    """A big satin hair bow: two puffy lobes (the ribbon's loops, seen flat from the front: pinched
    at the knot, swelling into a round 'D' end, an ink fold line on each), a plump knot, and two
    short tails with V-notched ends hanging under it. -> (pieces, frame matrix)."""
    # frame: local X across the bow, local Z up the bow, local -Y = the way it faces
    Rb = Matrix.Rotation(tilt, 4, "X") @ Matrix.Rotation(roll, 4, "Y")
    F = Matrix.Translation(knot_pos) @ Rb @ Matrix.Diagonal(Vector((size, size, size, 1.0)))
    bn = (Rb.to_3x3() @ Vector((0.0, -1.0, 0.0))).normalized()
    out = []
    lobes = []
    for s in (-1, 1):
        pts = [F @ Vector((s * x, 0.0, z)) for x, z in ((0.03, 0.0), (0.2, 0.05), (0.4, 0.1), (0.55, 0.12))]
        lobe = _sweep(pts, [r * size for r in (0.07, 0.17, 0.25, 0.26)], pal, seg=12, samples=4, cap0=0.0, cap1=0.75,
                      flat=0.5, up=bn, name="bowloop")
        lobes.append(lobe)
        out.append(lobe)
    # an ink fold line on the front of each lobe: the loop's inner edge, an arc from the knot round
    # toward the lobe's end and back
    ray = _bvh(lobes)
    for s in (-1, 1):
        pts, nrms = [], []
        for k in range(7):
            t = k / 6
            a = _lerp(-0.85, 0.95, t) * math.pi / 2
            x = 0.13 + 0.27 * math.cos(a)
            z = 0.06 + 0.15 * math.sin(a) + 0.04 * x
            o = F @ Vector((s * x, -0.5, z))
            hit = ray(o, -bn)
            if hit:
                pts.append(hit[0] + hit[1] * 0.012)
                nrms.append(hit[1])
        if len(pts) > 3:
            out.append(S._ink(pts, nrms, 0.026, samples=3, taper=0.35, name="bowfold"))
    # the knot: a plump rounded block in front of the pinched ends
    out.append(_ellipsoid(pal2, F @ Vector((0.0, -0.04, 0.02)), (0.12 * size, 0.11 * size, 0.13 * size), Rb,
                          seg=12, rings=8, name="bowknot"))
    # tails: flat ribbon ends hanging down and out from under the knot, V-notched
    basis = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))   # local XY -> bow XZ, Z -> -bow Y
    for s in (-1, 1):
        a0, a1 = Vector((0.03, -0.04)), Vector((0.24, -0.43))
        ax = (a1 - a0).normalized()
        nx = Vector((ax.y, -ax.x))
        w0, w1 = 0.075, 0.1
        poly = [a0 + nx * w0, a1 + nx * w1 + ax * 0.03, a1 - ax * 0.05, a1 - nx * w1 + ax * 0.03, a0 - nx * w0]
        poly = [(s * p.x, p.y) for p in poly]
        if s < 0:
            poly = list(reversed(poly))
        out.append(_prism(poly, 0.05, F @ Matrix.Translation((0.0, 0.03, 0.0)) @ basis, pal2, bevel=0.018, segs=2,
                          name="bowtail"))
    return out, F


def feat_polkadottie(c):
    """Turquoise with white polka dots of three sizes scattered over leg, heel and foot (none on the
    face or the cuff band), a big hot-pink satin bow sitting on the front of the rim (two puffy
    lobes, a knot, two V-notched tails over the cuff), three ink lashes flicking off each googly
    eye and pink blush cheeks under a happy smile."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    dot = hexcol(f"{tid}_dot", "#FFFFFF")
    bow = hexcol(f"{tid}_bow", "#FF5FA2")
    bow2 = hexcol(f"{tid}_bow_knot", "#F0498F")
    cheek = hexcol(f"{tid}_cheek", "#FF8FBF")
    out = []
    # ---- polka dots: a Poisson scatter (big ones first) on the outer surface, kept off the face,
    # the cuff band and the sole
    rng = random.Random(11)
    cands = []
    for poly in c._polys:
        vs = [c._verts[i] for i in poly]
        for k in range(1, len(vs) - 1):
            area = (vs[k] - vs[0]).cross(vs[k + 1] - vs[0]).length / 2
            cands.append((vs[0], vs[k], vs[k + 1], area))
    tot = sum(t[3] for t in cands)
    cum, run = [], 0.0
    for t in cands:
        run += t[3]
        cum.append(run)
    def sample():
        u = rng.random() * tot
        a, b, e, _ar = cands[min(bisect.bisect_left(cum, u), len(cands) - 1)]
        r1, r2 = rng.random(), rng.random()
        if r1 + r2 > 1.0:
            r1, r2 = 1.0 - r1, 1.0 - r2
        return a + (b - a) * r1 + (e - a) * r2

    face_lo = c.mouth_z - 0.24

    def allowed(p, r):
        if p.z + r > c.cuff_z - 0.06:
            return False
        ang = math.atan2(p.x, -p.y)
        if p.z > face_lo - r and abs(ang) < 1.3 and p.y < 0:
            return False
        return True

    dots = []
    for r, tries in ((0.17, 900), (0.12, 1400), (0.075, 2200)):
        for _k in range(tries):
            q = sample()
            o = Vector((0.0, 0.0, q.z))
            if c.FOOT and q.z < c.instep_z:
                o = _inside_point(c, q)
            hit = c.ray(o, q - o) if (q - o).length > 1e-4 else None
            if hit is None:
                continue
            p, n = hit
            if n.z < -0.55 or not allowed(p, r):
                continue
            if any((p - p2).length < r + r2 + 0.15 for p2, _n2, r2 in dots):
                continue
            dots.append((p, n, r))
    for p, n, r in dots:
        out.append(_surface_disc(c, p, n, r, dot, lift=0.012, seg=12 if r > 0.15 else (11 if r > 0.1 else 8),
                                 rings=2 if r > 0.15 else 1, name="dot"))
    # ---- the bow on the front of the rim, leaning back, cocked a little toward the toe
    kp = Vector((0.0, -(c.top_r - 0.04), h + 0.12))
    bow_parts, _F = _bow(bow, bow2, kp, math.radians(-22), math.radians(-12) * d, size=1.22)
    out += bow_parts
    # ---- lashes and blush
    out += _lashes(c)
    out += _cheeks(c, cheek)
    return out


def _inside_point(c, q):
    """A point inside the foot / heel near q, to cast a ray out through q from (on the foot's centre
    line, the heel's centre or the leg axis, whichever is nearest)."""
    a, b = c.foot_axis[0], c.toe_c
    ab = b - a
    t = max(0.0, min(1.0, (q - a).dot(ab) / max(ab.length_squared, 1e-6)))
    cands = [a + ab * t, Vector(c.heel_c), Vector((0.0, 0.0, max(q.z, c.heel_c.z)))]
    return min(cands, key=lambda o: (o - q).length)


def rig_polkadottie(R):
    ids = R.idx("bowloop bowfold bowknot bowtail")
    knot = R.cen(R.idx("bowknot"))
    R.add("Bow", "Cuff", knot, knot + Vector((0.0, 0.12, 0.38)), "hat")
    R.put(ids, ("bone", "Bow"))
    R.put(R.idx("lash"), ("bone", "Leg4"))


# ------------------------------------------------------------------ meridians (lines along the knit)
def _instep_centre(c):
    """(x, z) in the R frame (toe +X) of the instep curve's centre: the front line of the leg bends
    into the top of the foot round a circle tangent to both (socks._Shape: the rings round the
    instep fan out from it). Solved from SockCtx: the front line x_f at instep_z, the foot's top
    line (foot axis lifted foot_r) and instep_z."""
    al = c.foot_alpha
    x_f = c.radius_at(c.instep_z, (c.d or 1.0) * math.pi / 2)
    pa_z = c.foot_axis[0].z
    ri = (x_f * math.sin(al) + (c.instep_z - pa_z) * math.cos(al) - c.foot_r) / (1.0 - math.sin(al))
    return Vector((x_f + ri, c.instep_z)), ri


def _meridian_frames(c, z_top, dz=0.2, n_fan=12, foot_step=0.2, toe_stop=0.3):
    """Ring frames from z_top down the leg, round the instep and along the foot: [(O, w)] in WORLD
    space, O a point inside the body, w the unit direction (in the ring's plane, perpendicular to Y)
    toward the toe side / the top of the foot. A meridian at angle a (0 = the face side -Y, pi/2 =
    the toe side, pi = the back, -pi/2 = the heel / sole) is the body hit of the ray from O along
    w * sin(a) + (-Y) * cos(a) - so it follows the knit like a pyjama stripe: down the shin onto
    the instep, down the back round the heel onto the sole."""
    d = c.d or 1.0
    out = []
    n = max(2, round((z_top - c.instep_z) / dz))
    for k in range(n):
        out.append((Vector((0.0, 0.0, _lerp(z_top, c.instep_z, k / n))), Vector((d, 0.0, 0.0))))
    if not c.FOOT:
        return out
    Q, _ri = _instep_centre(c)
    al = c.foot_alpha
    th_end = math.pi / 2 - al
    O_end = None
    for k in range(n_fan + 1):
        th = th_end * k / n_fan
        dv = Vector((-math.cos(th), 0.0, -math.sin(th)))
        qw = Vector((d * Q.x, 0.0, Q.y))
        dw = Vector((d * dv.x, 0.0, dv.z))
        hf = c.ray(qw, dw)
        if hf is None:
            continue
        hg = c.ray(hf[0] + dw * 0.02, dw)
        if hg is None:
            continue
        F, G = hf[0], hg[0]
        out.append(((F + G) / 2, (F - G).normalized()))
        O_end = (F + G) / 2
    a0, a1 = c.foot_axis
    ax = (a1 - a0).normalized()
    nup = Vector((-ax.z, 0.0, ax.x))               # up, perpendicular to the foot axis
    nup = nup if nup.z > 0 else -nup
    t0 = (O_end - a0).dot(ax) if O_end is not None else 0.0
    t1 = (a1 - a0).length - toe_stop
    m = max(1, round((t1 - t0) / foot_step))
    for k in range(1, m + 1):
        out.append((a0 + ax * _lerp(t0, t1, k / m), nup.copy()))
    return out


def _meridian(c, frames, a, lift=0.015):
    """Points and normals of the meridian at angle a (see _meridian_frames), lifted off the body."""
    pts, nrms = [], []
    for O, w in frames:
        dv = w * math.sin(a) + Vector((0.0, -math.cos(a), 0.0))
        hit = c.ray(O, dv)
        if hit:
            pts.append(hit[0] + hit[1] * lift)
            nrms.append(hit[1])
    return pts, nrms


# ------------------------------------------------------------------ Pisolino Pigiamino
def _star_poly(r, k=5, inner=0.45, rot=0.0):
    return [((r if j % 2 == 0 else r * inner) * math.cos(rot + math.pi / 2 + math.pi * j / k),
             (r if j % 2 == 0 else r * inner) * math.sin(rot + math.pi / 2 + math.pi * j / k)) for j in range(2 * k)]


def _moon_poly(r, n=8, s=0.45, r2=0.85, rot=0.0):
    """A crescent bulging toward +X: the arc of a circle (radius r) minus a circle of radius r2 * r
    shifted s * r toward -X; the two arcs meet where the circles cross."""
    x = (r2 * r2 - 1.0 - s * s) / (2 * s)
    y = math.sqrt(max(1.0 - x * x, 0.0))
    t1 = math.atan2(y, x)
    t2 = math.atan2(y, x + s)
    pts = [(r * math.cos(_lerp(t1, -t1, j / n)), r * math.sin(_lerp(t1, -t1, j / n))) for j in range(n + 1)]
    pts += [(r * (-s + r2 * math.cos(_lerp(-t2, t2, j / n))), r * r2 * math.sin(_lerp(-t2, t2, j / n)))
            for j in range(1, n)]
    cs, sn = math.cos(rot), math.sin(rot)
    return [(px * cs - py * sn, px * sn + py * cs) for px, py in pts]


def _flat_on(p, n, poly, depth, pal, up=Z, lift=0.012, name="decal"):
    """A thin flat shape (2D poly) standing on a surface at p (normal n), turned so local +Y follows
    `up` (made perpendicular to n)."""
    mat = Matrix.Translation(p + n * lift) @ _frame(n, up)
    return _prism(poly, depth, mat, pal, bevel=0.0, outline=False, name=name)


def feat_pisolino(c):
    """Periwinkle pyjamas: thin white pinstripes running down the leg and on round the heel and the
    instep to the toe, like stripes knitted into the fabric (the face keeps a clean panel between
    the stripes); a long droopy navy nightcap over the rim (a soft rolled brim, the crown leaning
    to the heel side) whose tail flops over to the heel side and droops down, well clear of the
    head, sprinkled with tiny yellow stars and crescent moons and ending in a fat white pompom
    beside the brim; heavy half-closed lids (the shared 'tired' face) over a small sleepy 'o'."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    stripe = hexcol(f"{tid}_stripe", "#F4F6FF")
    cap = hexcol(f"{tid}_cap", "#34407F")
    brim = hexcol(f"{tid}_cap_band", "#2B356E")
    starc = hexcol(f"{tid}_star", "#FFD84A")
    pom = hexcol(f"{tid}_pom_fluff", "#F6F6FC")
    out = []
    # ---- pinstripes along the knit (meridians), none across the face panel
    frames = _meridian_frames(c, c.cuff_z - 0.02, dz=0.18, n_fan=14, foot_step=0.16, toe_stop=0.22)
    nstripe = 18
    face_lo = c.mouth_z - 0.3
    for k in range(nstripe):
        a = TAU * (k + 0.5) / nstripe
        aw = math.atan2(math.sin(a), math.cos(a))
        fr = frames
        if abs(aw) < 1.15:            # the face panel: the stripe starts under the chin
            fr = [(O, w) for O, w in frames if O.z < face_lo]
        pts, nrms = _meridian(c, fr, a)
        if len(pts) > 2:
            out.append(_ribbon(pts, nrms, 0.024, pal=stripe, taper=0.85, samples=1, name="stripe"))
    # ---- nightcap: a rolled brim round the rim, the crown leaning to the heel side, the tail
    # flopping over and hanging beside the head
    out.append(_lathe_roll(c.top_r + 0.03, h - 0.05, 0.13, 0.11, brim, seg=24, nb=8, name="capbrim"))
    path = [Vector((d * x, y, h + z)) for x, y, z in ((0.0, 0.0, -0.06), (-0.04, 0.02, 0.28), (-0.2, 0.06, 0.6),
                                                       (-0.55, 0.12, 0.76), (-0.95, 0.2, 0.64), (-1.26, 0.26, 0.36),
                                                       (-1.4, 0.3, 0.04))]
    radii = [c.top_r + 0.0, 0.62, 0.43, 0.3, 0.22, 0.16, 0.13]
    capp = _sweep(path, radii, cap, seg=16, samples=4, cap0=None, cap1=0.6, name="cap")
    dense = S._catmull([Vector(p) for p in path], 4)
    capp.rig = dict(path=dense, base=Vector(path[2]), svals=_ring_arcs(dense, 16, len(capp.mesh.vertices)))
    out.append(capp)
    ray = _bvh([capp])
    # stars and moons sprinkled over the cap (cast out of its centre line)
    rng = random.Random(5)
    acc = [0.0]
    for p0, p1 in zip(dense, dense[1:]):
        acc.append(acc[-1] + (p1 - p0).length)
    L = acc[-1]

    def at(s):
        s *= L
        for k in range(len(dense) - 1):
            if acc[k + 1] >= s:
                f = (s - acc[k]) / max(acc[k + 1] - acc[k], 1e-9)
                return dense[k].lerp(dense[k + 1], f), (dense[k + 1] - dense[k]).normalized()
        return dense[-1], (dense[-1] - dense[-2]).normalized()

    spots = [(0.12, 0.2), (0.15, 2.3), (0.2, 4.2), (0.28, 1.1), (0.33, 3.3), (0.42, 5.4), (0.47, 0.4),
             (0.55, 2.6), (0.63, 4.6), (0.7, 1.5), (0.8, 3.6), (0.87, 0.7)]
    for k, (s, ph) in enumerate(spots):
        o, t = at(s)
        u = Z - t * Z.dot(t)
        if u.length < 1e-3:
            u = Vector((1.0, 0.0, 0.0))
        u.normalize()
        v = t.cross(u)
        dv = u * math.cos(ph * d) + v * math.sin(ph * d)
        hit = ray(o, dv)
        if not hit:
            continue
        p, n = hit
        r = 0.085 if k % 3 == 1 else 0.08
        if k % 3 == 1:
            poly = _moon_poly(r, rot=rng.uniform(0, TAU))
        else:
            poly = _star_poly(r, rot=rng.uniform(0, TAU))
        out.append(_flat_on(p, n, poly, 0.022, starc, up=t, lift=0.011, name="capstar"))
    # fat lumpy pompom on the tip
    tip = Vector(path[-1]) + (Vector(path[-1]) - Vector(path[-2])).normalized() * 0.16
    out.append(_blob(pom, tip, Matrix.Identity(3), (0.25, 0.25, 0.25), seg=10, rings=5, cut=-0.95, lump=0.1,
                     seed=3, name="pompom"))
    # the cap closes the opening: the clothespin grips its crown
    c.pin_z = max(v.co.z for v in capp.mesh.vertices if math.hypot(v.co.x, v.co.y) < 0.3) + 0.08
    # ---- a small sleepy 'o' mouth
    mz = c.mouth_z + 0.02

    def oval(g):
        w, hh = 0.065 + g, 0.08 + g
        f = lambda u: hh * max(1 - (u / w) ** 2, 0.0) ** 0.5  # noqa: E731
        return -w, w, (lambda u: mz + f(u)), (lambda u: mz - f(u))
    out += S._inked(c.face_point, oval, S.C_PINKMOUTH, border=0.032, n=11, name="mouth")
    return out


def _ring_arcs(P, seg, nverts):
    """Arc length along P of every vertex of a sockfeat_c._sweep built through P (open start, domed
    end): ring k holds vertices k*seg .. k*seg+seg-1, the end dome (and its tip) gets the full length.
    rigging uses it (_ArcChain) so a fat, sharply bent tube is weighted by its own rings instead of
    by the nearest point of its centre line."""
    acc = [0.0]
    for a, b in zip(P, P[1:]):
        acc.append(acc[-1] + (b - a).length)
    return [acc[min(v // seg, len(P) - 1)] for v in range(nverts)]


class _ArcChain(rigging.Chain):
    """A rigging.Chain whose arc position of a point is the arc of the nearest vertex of the tube it
    was built for (svals from _ring_arcs), so the inside of a sharp bend never jumps ahead."""

    def __init__(self, path, bones, knots, base, pts, svals, **kw):
        super().__init__(path, bones, knots, base, **kw)
        from mathutils.kdtree import KDTree
        self.kd = KDTree(len(pts))
        for k, q in enumerate(pts):
            self.kd.insert(Vector(q), k)
        self.kd.balance()
        self.sv = svals

    def arc_of(self, pts):
        return np.array([self.sv[self.kd.find(Vector(tuple(q)))[1]] for q in pts])


def _lathe_roll(R, zc, rh, rv, pal, seg=24, nb=10, name="roll"):
    """A soft rolled band round the leg axis: an elliptical cross-section (rh across, rv up) swept
    round a circle of radius R at height zc."""
    bm = bmesh.new()
    rows = []
    for k in range(seg):
        a = TAU * k / seg
        row = []
        for j in range(nb):
            b = TAU * j / nb
            r = R + rh * math.cos(b)
            row.append(bm.verts.new((math.cos(a) * r, math.sin(a) * r, zc + rv * math.sin(b))))
        rows.append(row)
    for k in range(seg):
        k2 = (k + 1) % seg
        for j in range(nb):
            j2 = (j + 1) % nb
            bm.faces.new((rows[k][j], rows[k2][j], rows[k2][j2], rows[k][j2]))
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _piece(bm, pal, name)


def rig_pisolino(R):
    i_cap = R.idx("cap")[0]
    tg = R.info["tags"][i_cap]
    path = tg["path"]
    names = ["Cap1", "Cap2", "Cap3"]
    tmp = rigging.Chain(path, names, [0, 1, 2, 3], R.base)
    s0 = float(tmp.arc_of([tuple(tg["base"])])[0])
    L = tmp.length()
    kn = [s0 + (L - s0) * j / 3 for j in range(4)]

    def cuff(p):
        return {"Cuff": 1.0}
    ch = _ArcChain(path, names, kn, cuff, R.verts([i_cap]), tg["svals"], root_blend=(s0 - 0.25, s0 + 0.1))
    for j in range(3):
        R.add(names[j], "Cuff" if j == 0 else names[j - 1], ch.at(kn[j]), ch.at(kn[j + 1]), "dangle",
              index=1, seg=j + 1, hint=dict(swing=SWING["Cap"]))
    R.put([i_cap] + R.idx("capstar"), ("chain", ch))
    R.put(R.idx("capbrim"), ("bone", "Cuff"))
    R.put(R.idx("pompom"), ("bone", "Cap3"))
    R.put(R.idx("stripe"), ("skin",))


# ------------------------------------------------------------------ Bambino Calzino
def _ellipse_r(a, b, rot=0.0, bump=None):
    """rfn(theta) of an ellipse (radii a, b, turned by rot) for sockfeat_c._blob_decal, plus an
    optional bump (theta_c, height, sharpness) - a duck's tail."""
    def rfn(th):
        t = th - rot
        r = 1.0 / math.sqrt((math.cos(t) / a) ** 2 + (math.sin(t) / b) ** 2)
        if bump:
            tc, hb, k = bump
            r += hb * max(0.0, math.cos(th - tc)) ** k
        return r
    return rfn


def _print_shapes(c, ang, z, front, shapes):
    """Flat printed shapes on the leg round (ang, z): shapes = [(u, v, rfn, lift, thick, pal, name)]
    with u toward `front` (+1 = toward +angle) and v up, rfn in that local frame (mirrored here)."""
    out = []
    r = c.radius_at(z, ang)
    for u, v, rfn, lift, thick, pal, name in shapes:
        if front > 0:
            f = rfn
        else:
            f = (lambda th, rfn=rfn: rfn(math.pi - th))
        out.append(_blob_decal(c, ang + front * u / r, z + v, f, lift, thick, pal, rings=2, seg=14, name=name))
    return out


def feat_bambino(c):
    """A tiny cream-yellow baby sock (the short body) with a ribbed baby-blue cuff: a baby-blue
    pacifier in its mouth (an oval shield with two vents, a knob and a ring handle standing out in
    front), one brown curl of hair springing out of the front of the opening and curling forward,
    rosy cheeks, and a little yellow rubber duck printed on the toe side of the leg (inked, orange
    beak, facing the front)."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    shield = hexcol(f"{tid}_paci_shield", "#9AD8FF")
    ringc = hexcol(f"{tid}_paci_ring", "#5AB0F0")
    vent = hexcol(f"{tid}_paci_vent", "#3A86C8")
    hair = hexcol(f"{tid}_hair", "#8A5A2E")
    cheek = hexcol(f"{tid}_cheek", "#FF9C9C")
    duck = hexcol(f"{tid}_duck", "#FFC928")
    duck2 = hexcol(f"{tid}_duck_wing", "#F2AE12")
    beak = hexcol(f"{tid}_duck_beak", "#FF8A2A")
    out = []
    # ---- pacifier: an oval shield standing off the mouth, knob and ring handle in front
    mz = c.mouth_z - 0.03
    p, n = c.face_point(0.0, mz)
    n = Vector((n.x, n.y, 0.0)).normalized()
    sc = p + n * 0.075
    out.append(_puck(sc, n, Z, 0.25, 0.15, 0.07, shield, p=2.6, bevel=0.35, bulge=0.025, seg=24, rings=3,
                     name="paci"))
    side = Z.cross(n).normalized()
    for s in (-1, 1):
        out.append(_ellipsoid(vent, sc + side * (s * 0.135) + n * 0.045, (0.035, 0.05, 0.012), _frame(n, Z), seg=10,
                              rings=3, outline=False, name="pacivent"))
    out.append(K.sphere(ringc, 0.062, Matrix.Translation(sc + n * 0.06), seg=12, rings=6, name="paciknob"))
    tilt = math.radians(28)
    ax = (n * math.cos(tilt) + Z * math.sin(tilt)).normalized()
    out.append(K.torus(ringc, 0.115, 0.03, Matrix.Translation(sc + n * 0.115 - Z * 0.035) @ _frame(ax, Z), seg=20, mseg=6,
                       name="pacring"))
    # ---- a single curl of hair springing out of the opening: a short stem, then a fat spiral that
    # curls over toward the toe side, its plane turned mostly to the front so the '@' reads there
    u = Vector((math.sin(math.radians(68)) * d, -math.cos(math.radians(68)), 0.0))
    base = Vector((-0.1 * d, -(c.open_r - 0.3), h - 0.14))
    ab = [(0.0, 0.0), (0.0, 0.18), (0.04, 0.36), (0.15, 0.47), (0.29, 0.46), (0.37, 0.35), (0.34, 0.22),
          (0.23, 0.17), (0.15, 0.24), (0.17, 0.33), (0.25, 0.34)]
    pts = [base + u * a + Z * b for a, b in ab]
    rr = [0.09, 0.088, 0.085, 0.08, 0.075, 0.07, 0.064, 0.058, 0.052, 0.046, 0.04]
    out += _strand(pts, rr, hair, width=0.03, seg=8, samples=3, cap1=1.0, name="curl")
    # ---- rosy cheeks
    out += _cheeks(c, cheek, dx=0.2, dz=-0.36, size=(0.12, 0.08))
    # ---- the rubber duck print on the toe side, facing the front
    a0, z0 = d * 1.56, _lerp(c.mouth_z, c.cuff_z, 0.5) - 0.04
    fr = -d
    ink = K.BLACK
    k = 1.55

    def E(a, b, rot=0.0, bump=None):
        return _ellipse_r(a * k, b * k, rot, (bump[0], bump[1] * k, bump[2]) if bump else None)
    tail = (math.pi - 0.75, 0.07, 6)
    out += _print_shapes(c, a0, z0, fr, [
        (-0.02 * k, 0.0, E(0.17 + 0.022, 0.095 + 0.022, bump=tail), 0.006, 0.01, ink, "duck_ink"),
        (0.105 * k, 0.12 * k, E(0.097, 0.097), 0.006, 0.01, ink, "duck_ink"),
        (0.195 * k, 0.105 * k, E(0.068, 0.045, rot=-0.15), 0.006, 0.01, ink, "duck_ink"),
        (-0.02 * k, 0.0, E(0.17, 0.095, bump=tail), 0.018, 0.006, duck, "duck"),
        (0.105 * k, 0.12 * k, E(0.075, 0.075), 0.019, 0.006, duck, "duck"),
        (0.2 * k, 0.105 * k, E(0.05, 0.027, rot=-0.15), 0.018, 0.006, beak, "duck"),
        (-0.05 * k, 0.005 * k, E(0.085, 0.045, rot=0.25), 0.026, 0.004, duck2, "duck"),
        (0.12 * k, 0.135 * k, E(0.017, 0.019), 0.026, 0.004, ink, "duck"),
    ])
    return out


def rig_bambino(R):
    c = R.c
    ids = R.idx("paci pacivent paciknob pacring")
    ctr = R.cen(R.idx("paci"))
    # like AnkleBiter's Jaw: an upright bone hinged behind the face, so turning it about +X (or
    # sliding it down its -Y) bobs the pacifier down a little - sucking. It rides the face block
    # (Leg4, like AnkleBiter's), even though the short sock's mouth sits on the Leg3/Leg4 blend
    R.add("Paci", "Leg4", (0.0, 0.8, ctr.z), (0.0, 0.8, ctr.z + 0.3), "jaw",
          hint=dict(turn=PACI["turn"], slide=PACI["slide"]))
    R.put(ids, ("bone", "Paci"))
    curl = R.idx("curl curl_core")
    v = R.verts(curl)
    lo = Vector(v[v[:, 2].argmin()])
    top = Vector(v.mean(axis=0))
    head = Vector((lo.x, lo.y, c.h))
    R.add("Curl", "Cuff", head, Vector((top.x, top.y, v[:, 2].max())), "spring", hint=dict(wobble=WOBBLE["Curl"]))
    R.put(curl, ("bone", "Curl"))
    R.put(R.idx("duck duck_ink"), ("skin",))


# ------------------------------------------------------------------ Jingleo Bellini
def _holly_poly(L, W, spikes=3):
    """A holly leaf outline along +X (0 .. L): pointed tip, `spikes` sharp points per side
    between scalloped bays."""
    pts = [(0.0, 0.0)]
    n = spikes
    upper, lower = [], []
    for k in range(1, n + 1):
        x0, x1 = L * (k - 0.5) / (n + 0.6), L * k / (n + 0.6)
        w0 = W * math.sin(math.pi * min(x0 / L, 0.92)) ** 0.7 * 0.62
        w1 = W * math.sin(math.pi * min(x1 / L, 0.92)) ** 0.7 * 1.05
        upper += [(x0, w0), (x1, w1)]
        lower += [(x0, -w0), (x1, -w1)]
    pts += upper + [(L, 0.0)] + list(reversed(lower))
    return pts


def _snowflake(c, ang, z, size, pal, lift=0.014, spin=0.0, name="snowflake"):
    """A six-armed snowflake printed on the leg: flat ribbons (arms with a V of short branches)."""
    out = []
    r = c.radius_at(z, ang)

    def surf(u, v):
        p, n = c.surface(ang + u / r, z + v)
        return p + n * lift, n

    for k in range(6):
        a = spin + TAU * k / 6
        dv = (math.cos(a), math.sin(a))
        arm = [surf(dv[0] * size * f, dv[1] * size * f) for f in (0.0, 0.5, 1.0)]
        out.append(_ribbon([p for p, _n in arm], [n for _p, n in arm], size * 0.1, pal=pal, taper=0.7, samples=1,
                           name=name))
        for s in (-1, 1):
            b = a + s * math.radians(50)
            o = (dv[0] * size * 0.55, dv[1] * size * 0.55)
            br = [surf(o[0] + math.cos(b) * size * f, o[1] + math.sin(b) * size * f) for f in (0.0, 0.35)]
            out.append(_ribbon([p for p, _n in br], [n for _p, n in br], size * 0.08, pal=pal, taper=0.7, samples=1,
                               name=name))
    return out


def feat_jingleo(c):
    """A jolly Christmas stocking: red with green heel and toe, a big lumpy white fur cuff (Santa's
    trim) rolled over the rim, a holly sprig on the front of the fur (two spiky leaves, three red
    berries), a gold jingle bell (equator band, a dark slot with round ends, the little ball
    showing in it) hooked on a loop sewn into the toe tip and swung forward off it, two white
    snowflakes printed on the leg, and a happy face with rosy cheeks."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    fur = hexcol(f"{tid}_fur", "#FBFBF8")
    holly = hexcol(f"{tid}_holly_leaf", "#1E7A3C")
    berry = hexcol(f"{tid}_berry", "#E3122A")
    bell = hexcol(f"{tid}_bell", "#F2C14E")
    bell2 = hexcol(f"{tid}_bell_band", "#D9A23A")
    slot = hexcol(f"{tid}_bell_slot", "#3A2412")
    snow = hexcol(f"{tid}_snowflake", "#FFFFFF")
    cheek = hexcol(f"{tid}_cheek", "#FF9AA0")
    out = []
    # ---- Santa's fur trim: a tall lumpy roll over the rim and the band
    Rc, zc, rh, rv = c.top_r + 0.05, h - 0.22, 0.27, 0.33
    out.append(_fluff_roll(c, fur, Rc, zc, rh, rv, lumps=11, n_a=66, name="fur"))
    # ---- holly sprig on the front of the fur, a little to the toe side
    a0 = d * 0.5
    nrm = Vector((math.sin(a0), -math.cos(a0), 0.0))
    pc = Vector((0.0, 0.0, zc + 0.04)) + nrm * (Rc + rh * 0.86)
    nrm2 = (nrm + Z * 0.35).normalized()
    side = Z.cross(nrm2).normalized()
    up = nrm2.cross(side).normalized()
    for ang_deg, L in ((148, 0.46), (18, 0.42)):
        a = math.radians(ang_deg)
        along = side * (math.cos(a) * d) + up * math.sin(a)
        ln = nrm2.cross(along).normalized()
        mat = Matrix.Translation(pc + nrm2 * 0.03) @ Matrix((along, ln, nrm2)).transposed().to_4x4() \
            @ Matrix.Rotation(0.18, 4, "X")
        out.append(_prism(_holly_poly(L, 0.2), 0.035, mat, holly, bevel=0.012, segs=1, name="holly"))
        # a vein down the middle
        vp = [mat @ Vector((x, 0.0, 0.02)) for x in (0.04, L * 0.5, L * 0.86)]
        out.append(S._ink(vp, [nrm2] * 3, 0.012, seg=4, samples=2, taper=0.4, pal=hexcol(f"{tid}_holly_vein", "#5DB86E"),
                          name="hollyvein"))
    for k, (du, dv_) in enumerate(((-0.02, 0.06), (0.1, -0.02), (-0.08, -0.07))):
        bp = pc + side * (du * d) + up * dv_ + nrm2 * 0.09
        out.append(K.sphere(berry, 0.068, Matrix.Translation(bp), seg=12, rings=7, name="berry"))
        out.append(_ellipsoid(K.WHITE, bp + (nrm2 * 0.8 + up * 0.45 - side * 0.3 * d).normalized() * 0.062,
                              (0.018, 0.012, 0.006), _frame(nrm2, up), seg=6, rings=3, outline=False, name="glint"))
    # ---- jingle bell hanging off the toe tip: a loop sewn into the tip, the bell's crown ring
    # hooked into it, the bell swung forward a little (it would touch the floor hanging straight)
    tip = Vector(c.toe_tip)
    fd = Vector(c.foot_dir)
    loop_c = tip + fd * 0.03 - Z * 0.01
    out.append(K.torus(bell2, 0.075, 0.022, Matrix.Translation(loop_c) @ _frame(Vector((0.0, 1.0, 0.0)), Z),
                       seg=16, mseg=5, name="bellloop"))
    rb = 0.23
    tb = math.radians(45)
    ab = Vector((-math.sin(tb) * d, 0.0, math.cos(tb)))          # the bell's axis (crown direction)
    hook = loop_c + Vector((d * 0.075, 0.0, -0.02))
    bc = hook - ab * (rb + 0.07)
    B = _frame(ab, Vector((0.0, 1.0, 0.0)))                       # local Z = the bell's axis
    Bt = Matrix.Translation(bc) @ B
    out.append(K.sphere(bell, rb, Bt, seg=18, rings=12, name="bell"))
    out.append(K.torus(bell2, rb * 1.0, 0.028, Bt @ Matrix.Translation((0.0, 0.0, 0.03)), seg=24, mseg=5, name="bellband"))
    out.append(K.torus(bell, 0.05, 0.019, Bt @ Matrix.Translation((0.0, 0.0, rb + 0.035)) @ Matrix.Rotation(math.pi / 2, 4, "X"),
                       seg=12, mseg=5, name="belltop"))
    # the slot: a dark line across the bottom (turned so it reads from the front and the side),
    # round holes at its ends, the little ball showing in the middle
    B3 = B.to_3x3()
    sl_ax = B3 @ Vector((math.cos(math.radians(50)) * d, -math.sin(math.radians(50)), 0.0))
    down = -(B3 @ Z)
    sp, sn = [], []
    for k in range(7):
        a = _lerp(-1.0, 1.0, k / 6) * math.radians(60)
        q = (sl_ax * math.sin(a) + down * math.cos(a)).normalized()
        sp.append(bc + q * (rb + 0.006))
        sn.append(q)
    out.append(S._ink(sp, sn, 0.032, seg=6, samples=2, pal=slot, name="bellslot"))
    for q in (sn[0], sn[-1]):
        out.append(_ellipsoid(slot, bc + q * (rb - 0.004), (0.055, 0.055, 0.016), _frame(q, Z), seg=10, rings=3,
                              outline=False, name="bellslot"))
    out.append(K.sphere(hexcol(f"{tid}_bell_ball", "#C9922E"), 0.055, Matrix.Translation(bc + down * (rb - 0.03)),
                        seg=10, rings=6, outline=False, name="bellball"))
    # ---- snowflakes printed on the leg (heel side, and low on the back-toe side)
    out += _snowflake(c, -d * 1.45, _lerp(c.instep_z, c.mouth_z, 0.6), 0.3, snow, spin=0.2)
    out += _snowflake(c, d * 2.3, _lerp(c.instep_z, c.mouth_z, 0.2), 0.22, snow, spin=-0.1)
    # ---- rosy cheeks
    out += _cheeks(c, cheek)
    return out


def rig_jingleo(R):
    ids = R.idx("bellloop bell bellband belltop bellslot bellball")
    head = R.cen(R.idx("bellloop"))
    bc = R.cen(R.idx("bell"))
    R.add("Bell", "Toe", head, bc + (bc - head).normalized() * 0.23, "dangle", index=1, seg=1,
          hint=dict(swing=SWING["Bell"]))
    R.put(ids, ("bone", "Bell"))
    R.put(R.idx("fur holly hollyvein berry"), ("bone", "Cuff"))
    R.put(R.idx("glint", "feat"), ("bone", "Cuff"))
    R.put(R.idx("snowflake"), ("skin",))


# ------------------------------------------------------------------ Ninjolino Stealthini
def _slit(c):
    """The hood's eye slit round the googly eyes: (U, top(u), bot(u)) - half length U along the
    leg's front (arc length) and the slit's top / bottom edge heights at arc position u. The top
    edge dips between the eyes (a frown: determined), the ends are pointed (an almond)."""
    U = c.eye_rim_r * 2 + 0.11
    ey = c.ey

    def top(u):
        t = min(abs(u) / U, 1.0)
        return ey + 0.44 * max(1 - t * t, 0.0) ** 0.5 * (0.6 + 0.4 * min(t / 0.42, 1.0))

    def bot(u):
        t = min(abs(u) / U, 1.0)
        return ey - 0.43 * max(1 - t * t, 0.0) ** 0.6
    return U, top, bot


def feat_ninjolino(c):
    """A sneaky ninja: an inky indigo sock wrapped in a darker hood (over the rim and the band, a
    mask down over the mouth, a pointed flap down the back) with an almond eye slit - its top edge
    dips between the eyes, so the googly eyes glare out under slanted lids; a red headband round
    the hood above the slit, knotted at the back with two long ribbon tails flowing out behind
    (a silver four-point star tucked in it on the toe side); grey bandage wraps round the ankle;
    the heel and toe in the hood's dark like tabi."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    hood = c.body_dark
    band = hexcol(f"{tid}_headband", "#E0403A")
    band2 = hexcol(f"{tid}_headband_knot", "#C4302C")
    wrapc = hexcol(f"{tid}_bandage", "#AEB0BE")
    steel = hexcol(f"{tid}_shuriken", "#D3DAE4")
    out = []
    ey = c.ey
    U, top, bot = _slit(c)
    # ---- the hood: one shell round the leg with the slit cut out of it
    z_top = h - 0.06
    fz = ey - 0.64                               # the mask's lower edge in front (over the mouth)

    def z_bot(a):
        t = _smooth((abs(a) - 0.9) / (math.pi - 0.9))
        return _lerp(fz, fz - 0.2, t) - 0.3 * max(0.0, -math.cos(a)) ** 8

    n1, n2, nu = 4, 5, 44
    nv = n1 + 1 + n2

    def col_z(a, k):
        r = c.radius_at(ey, a)
        u = a * r
        zh, zl = (top(u), bot(u)) if abs(u) < U else (ey + 0.01, ey - 0.01)
        zh, zl = max(zh, ey + 0.01), min(zl, ey - 0.01)
        if k <= n1:
            return _lerp(z_top, zh, k / n1)
        return _lerp(zl, z_bot(a), (k - n1 - 1) / n2)

    def grid(u, v):
        a = (u - 0.5) * TAU                      # u = 0.5 is the front
        k = round(v * nv)
        return a, col_z(a, k), 0.014

    def hole(i, k):
        a = ((i + 0.5) / nu - 0.5) * TAU
        return k == n1 and abs(a * c.radius_at(ey, a)) < U

    out.append(_shell(c, nu, nv, grid, 0.04, hood, wrap=True, hole=hole, wall_pal=K.BLACK, name="hood"))
    # ink lines along the slit's edges (the hood's own hull does not draw them head-on)
    for fn in (top, bot):
        pts, nrms = [], []
        for k in range(15):
            u = _lerp(-U, U, k / 14) * 0.995
            a = u / c.radius_at(ey, 0.0)
            p, n = c.surface(a, fn(u), 0.064)
            pts.append(p)
            nrms.append(n)
        out.append(S._ink(pts, nrms, 0.034, seg=5, samples=2, taper=0.25, name="slitline"))
    # slanted lids: the eyes glare (lid in the sock's indigo, leaning toward the nose)
    out += _lids(c, c.body, math.radians(122), math.radians(58), lean=0.2, lift=0.034, line_r=0.042, clip=0.3,
                 name="lid")
    # ---- the red headband over the hood, above the slit
    zb0, zb1 = top(c.eye_rim_r) + 0.12, top(c.eye_rim_r) + 0.36
    zb0 = max(zb0, ey + 0.5)
    zb1 = zb0 + 0.24

    def bgrid(u, v):
        return u * TAU, _lerp(zb0, zb1, v), 0.06

    out.append(_shell(c, 36, 2, bgrid, 0.06, band, wrap=True, name="headband"))
    zm = (zb0 + zb1) / 2
    pk, nk = c.surface(math.pi, zm)
    knot = pk + nk * 0.17
    out.append(_ellipsoid(band2, knot, (0.15, 0.11, 0.14), None, seg=12, rings=8, name="bandknot"))
    # two long tails flowing out behind, spreading apart and waving down
    for s in (-1, 1):
        pts = [knot + Vector((s * x, y, z)) for x, y, z in ((0.04, 0.02, 0.0), (0.24, 0.24, -0.1), (0.5, 0.42, -0.06),
                                                             (0.78, 0.58, -0.22), (1.02, 0.78, -0.16))]
        tail = _sweep(pts, [0.075, 0.085, 0.09, 0.095, 0.1], band, seg=10, samples=3, cap0=None, cap1=0.0, flat=0.28,
                      up=Vector((1.0, 0.0, 0.0)), name="bandtail")
        dense = S._catmull([Vector(p) for p in pts], 3)
        tail.rig = dict(path=dense, side=s, svals=_ring_arcs(dense, 10, len(tail.mesh.vertices)))
        out.append(tail)
    # the throwing star tucked in the band on the toe side
    a_s = d * 0.78
    ps, ns = c.surface(a_s, zm, 0.135)
    star = _star_poly(0.21, k=4, inner=0.32, rot=math.radians(18))
    out.append(_flat_on(ps, ns, star, 0.035, steel, up=Z, lift=0.0, name="shuriken"))
    out.append(_ellipsoid(hexcol(f"{tid}_shuriken_hole", "#2A2D3A"), ps + ns * 0.02, (0.035, 0.035, 0.012),
                          _frame(ns, Z), seg=10, rings=2, outline=False, name="shuriken_hole"))
    # ---- grey bandage wraps round the ankle: three overlapping slanted turns
    z0 = c.instep_z - 0.2
    for k in range(3):
        zc = z0 + 0.15 * k + 0.09

        def wgrid(u, v, zc=zc, k=k):
            a = u * TAU
            return a, zc + 0.07 * math.sin(d * a + 1.3 + k * 1.9) + _lerp(-0.08, 0.08, v), 0.012 + 0.012 * k

        out.append(_shell(c, 30, 1, wgrid, 0.035, wrapc, wrap=True, name="bandage"))
    return out


def rig_ninjolino(R):
    for i in R.idx("bandtail"):
        tg = R.info["tags"][i]
        b = 1 if tg["side"] < 0 else 2           # Band1 = the viewer's left (-X)
        names = [f"Band{b}_1", f"Band{b}_2"]
        L = float(tg["svals"][-1])
        kn = [0.0, L * 0.5, L]

        def leg4(p):
            return {"Leg4": 1.0}
        ch = _ArcChain(tg["path"], names, kn, leg4, R.verts([i]), tg["svals"], root_blend=(-0.05, 0.12))
        for j in range(2):
            R.add(names[j], "Leg4" if j == 0 else names[0], ch.at(kn[j]), ch.at(kn[j + 1]), "dangle", index=b,
                  seg=j + 1, hint=dict(swing=SWING["Band"]))
        R.put([i], ("chain", ch))
    R.put(R.idx("headband bandknot shuriken shuriken_hole"), ("bone", "Leg4"))
    R.put(R.idx("hood slitline bandage"), ("skin",))


# ------------------------------------------------------------------ Captain Sockbeard
def _tricorn(pal, trim, rc, a, k, base_mat, n=60):
    """A tricorn: a round crown on a brim turned up into three walls (one facing the front, two
    toward the back corners) that meet in three points (front-left, front-right, back). Lofted from
    one (r, z) profile per direction: the hollow under the crown (the sock's rim sits up in it),
    the brim out to the wall, up the wall's outside (a gold trim along its top edge), over the
    rolled edge, down its inside, across the brim floor and over the crown. -> (piece, wall(theta)
    -> (D, z_top))."""
    def wall(th):
        dl = abs(((th + math.pi / 3) % (2 * math.pi / 3)) - math.pi / 3)    # angle from the nearest wall
        D = a * (1.0 + k * (1.0 / math.cos(dl) - 1.0))
        zw = 0.34 + 0.24 * (dl / (math.pi / 3)) ** 2.2
        return D, zw

    bm = bmesh.new()
    rows = []
    gold_k = set()
    for j in range(n):
        th = TAU * j / n
        D, zw = wall(th)
        prof = [(rc - 0.04, 0.3), (rc - 0.04, -0.02), (D - 0.06, -0.02), (D + 0.03, 0.02), (D + 0.05, zw * 0.5),
                (D + 0.045, zw - 0.08), (D + 0.03, zw), (D - 0.02, zw + 0.035), (D - 0.07, zw), (D - 0.075, zw - 0.06),
                (D - 0.075, 0.09), (rc + 0.05, 0.08), (rc + 0.02, 0.42), (rc * 0.82, 0.62), (rc * 0.42, 0.69)]
        gold_k = {5, 6, 7, 8}
        sx, sy = math.sin(th), -math.cos(th)
        rows.append([bm.verts.new(base_mat @ Vector((r * sx, r * sy, z))) for r, z in prof])
    pole_top = bm.verts.new(base_mat @ Vector((0.0, 0.0, 0.7)))
    pole_bot = bm.verts.new(base_mat @ Vector((0.0, 0.0, 0.3)))
    pals = []
    m = len(rows[0])
    for j in range(n):
        j2 = (j + 1) % n
        bm.faces.new((pole_bot, rows[j2][0], rows[j][0]))
        pals.append(pal)
        for i in range(m - 1):
            bm.faces.new((rows[j][i], rows[j2][i], rows[j2][i + 1], rows[j][i + 1]))
            pals.append(trim if i in gold_k else pal)
        bm.faces.new((rows[j][m - 1], rows[j2][m - 1], pole_top))
        pals.append(pal)
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    pals = [pals[f.index] for f in bm.faces]
    return _piece(bm, pals, "tricorn"), wall


def feat_sockbeard(c):
    """A swaggering pirate in a sailor shirt (navy with wide cream stripes below the face): a big
    black tricorn (crown on a brim turned up into three walls, gold trim along their tops) with a
    friendly white skull and crossbones on the front wall; a black eye patch over the heel-side eye
    on a strap that runs round the head and climbs across the forehead over the other eye (with a
    cocky raised brow); a gold hoop earring on the toe side; a big lopsided grin with a gold tooth."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    hat = hexcol(f"{tid}_hat", "#26232C")
    trim = hexcol(f"{tid}_hat_trim_gold", "#F2C14E")
    skull = hexcol(f"{tid}_skull", "#F6F2E6")
    patch = hexcol(f"{tid}_eyepatch", "#1E1B24")
    gold = hexcol(f"{tid}_earring_gold", "#F7C548")
    teeth = hexcol(f"{tid}_teeth", "#FFFDF4")
    tooth_gold = hexcol(f"{tid}_tooth_gold", "#F0A818")
    out = []
    # ---- tricorn, tipped back a little and cocked toward the toe
    rc = c.top_r + 0.06
    base = (Matrix.Translation((0.0, 0.0, h - 0.1)) @ Matrix.Rotation(math.radians(-7), 4, "X")
            @ Matrix.Rotation(math.radians(-7) * d, 4, "Y"))
    tri, wall = _tricorn(hat, trim, rc, rc + 0.2, 0.5, base, n=48)
    out.append(tri)
    c.pin_z = (base @ Vector((0.0, 0.0, 0.7))).z + 0.08
    # skull and crossbones on the front wall
    D0, zw0 = wall(0.0)
    zc = zw0 * 0.47
    fmat = base @ Matrix.Translation((0.0, -(D0 + 0.058), zc)) @ Matrix.Rotation(math.pi / 2, 4, "X")
    # (local XY = the wall's face: X across, Y up; local +Z points out of the wall, toward the front)
    def on_wall(x, y, z=0.0):
        return fmat @ Vector((x, y, z))

    for s in (-1, 1):
        a0, a1 = Vector((-0.17 * s, -0.12)), Vector((0.17 * s, 0.1))
        p0, p1 = on_wall(a0.x, a0.y, 0.012), on_wall(a1.x, a1.y, 0.012)
        out.append(_sweep([p0, p1], [0.026, 0.026], skull, seg=8, samples=1, cap0=0.0, cap1=0.0, name="skullbone"))
        for q in (a0, a1):
            dq = (a1 - a0).normalized() if q is a1 else (a0 - a1).normalized()
            side = Vector((-dq.y, dq.x))
            for t in (-1, 1):
                kp = q + side * (0.026 * t) + dq * 0.008
                out.append(K.sphere(skull, 0.034, Matrix.Translation(on_wall(kp.x, kp.y, 0.014)), seg=8, rings=5,
                                    name="skullbone"))
    poly = [(0.105 * math.cos(math.radians(t)), 0.035 + 0.1 * math.sin(math.radians(t))) for t in range(-45, 226, 15)]
    poly += [(-0.065, -0.045), (-0.055, -0.105), (0.055, -0.105), (0.065, -0.045)]
    out.append(_prism(poly, 0.03, fmat @ Matrix.Translation((0.0, 0.0, 0.035)), skull, bevel=0.01, segs=1, name="skull"))
    frot = fmat.to_3x3().normalized().to_4x4()
    for s in (-1, 1):
        out.append(_ellipsoid(K.BLACK, on_wall(0.042 * s, 0.03, 0.05), (0.033, 0.036, 0.012), frot, seg=10, rings=3,
                              outline=False, name="skulleye"))
    out.append(_ellipsoid(K.BLACK, on_wall(0.0, -0.03, 0.05), (0.014, 0.018, 0.01), frot, seg=6, rings=2,
                          outline=False, name="skulleye"))
    for x in (-0.03, 0.0, 0.03):
        out.append(S._ink([on_wall(x, -0.06, 0.052), on_wall(x, -0.098, 0.052)], [base.to_3x3() @ Vector((0, -1, 0))] * 2,
                          0.008, seg=4, samples=1, name="skulleye"))
    # ---- eye patch over the heel-side eye, on a strap round the head
    e = 0 if d > 0 else 1                        # the heel-side eye (viewer's left on R)
    ctr, n = Vector(c.eyes[e]), Vector(c.eye_n[e]).normalized()
    pc = ctr + n * (c.eye_r * c.eye_flat + 0.02)
    out.append(_puck(pc, n, Z, 0.34, 0.31, 0.06, patch, p=2.3, bevel=0.35, bulge=0.035, seg=24, rings=3,
                     name="eyepatch"))
    ey = c.ey

    def strap_z(a):
        t = d * a
        return ey + 0.2 + 0.26 * math.tanh(3.0 * math.sin(t)) / math.tanh(3.0)

    def sgrid(u, v):
        a = (u - 0.5) * TAU
        return a, strap_z(a) + _lerp(-0.04, 0.04, v), 0.012

    out.append(_shell(c, 56, 1, sgrid, 0.03, patch, wrap=True, name="strap"))
    # a cocky raised brow over the other eye
    o = Vector(c.eyes[1 - e])
    bx = o.x
    top = o.z + c.eye_r
    sgn = 1.0 if bx > 0 else -1.0
    hits = [c.face_point(x, z, 0.014) for x, z in ((bx - sgn * 0.2, top + 0.13), (bx, top + 0.24), (bx + sgn * 0.24, top + 0.18))]
    out.append(S._ink([p for p, _n in hits], [nn for _p, nn in hits], 0.05, taper=0.45, name="brow"))
    # ---- gold hoop earring on the toe side, sticking out from the side of the head
    ze = ey - 0.12
    pe, ne = c.surface(d * 1.42, ze)
    ne = Vector((ne.x, ne.y, 0.0)).normalized()
    R_e = 0.16
    ec = pe + ne * (R_e * 0.86) - Z * (R_e * 0.55)
    out.append(K.torus(gold, R_e, 0.036, Matrix.Translation(ec) @ _frame(ne.cross(Z), Z), seg=22, mseg=6,
                       name="earring"))
    # ---- big lopsided grin with a gold tooth
    my = c.mouth_z + 0.02
    w = 0.3

    def gtop(u):
        return my + 0.08 * (u / w) ** 2 + 0.05 * d * (u / w) - 0.01

    def grin(g):
        ww = w + g

        def bot(u):
            return gtop(u) - g - 0.2 * max(1 - (abs(u) / ww) ** 2, 0.0) ** 0.75
        return -ww, ww, (lambda u: gtop(u) + g * 0.8), bot
    out += S._inked(c.face_point, grin, S.C_PINKMOUTH, border=0.034, lift=0.026, n=13, name="mouth")
    tw = 0.24
    tooth_h = 0.065
    edges = [_lerp(-tw, tw, k / 6) for k in range(7)]
    gold_i = 4 if d > 0 else 1
    for k in range(6):
        u0, u1 = edges[k] + 0.004, edges[k + 1] - 0.004
        out.append(S._plate(c.face_point, [_lerp(u0, u1, t / 3) for t in range(4)], (lambda u: gtop(u) - 0.012),
                            (lambda u: gtop(u) - 0.012 - tooth_h * (1 - 0.35 * (abs(u) / tw) ** 2)), 0.034,
                            tooth_gold if k == gold_i else teeth, name="tooth"))
    return out


def rig_sockbeard(R):
    c = R.c
    ids = R.idx("tricorn skull skullbone skulleye", "feat")
    top = R.hi(R.idx("tricorn")).z
    R.add("Hat", "Cuff", (0.0, 0.0, c.h), (0.0, 0.0, top), "hat")
    R.put(ids, ("bone", "Hat"))
    ring = R.idx("earring")
    v = R.verts(ring)
    ec = Vector(v.mean(axis=0))
    # the point where the hoop pierces the skin: its vertex nearest the leg axis, up top
    head = Vector(min(v, key=lambda q: math.hypot(q[0], q[1]) - 0.3 * q[2]))
    R.add("Earring", "Leg4", head, ec + (ec - head).normalized() * 0.16, "dangle", index=1, seg=1,
          hint=dict(swing=SWING["Earring"]))
    R.put(ring, ("bone", "Earring"))
    R.put(R.idx("eyepatch tooth"), ("bone", "Leg4"))
    R.put(R.idx("strap"), ("skin",))



FEATURES = {
    "PolkaDottie": feat_polkadottie,
    "Pisolino": feat_pisolino,
    "Bambino": feat_bambino,
    "Jingleo": feat_jingleo,
    "Ninjolino": feat_ninjolino,
    "Sockbeard": feat_sockbeard,
}
RIG = {
    "PolkaDottie": rig_polkadottie,
    "Pisolino": rig_pisolino,
    "Bambino": rig_bambino,
    "Jingleo": rig_jingleo,
    "Ninjolino": rig_ninjolino,
    "Sockbeard": rig_sockbeard,
}
SPEC_OVERRIDES = {
    "Pisolino": dict(mouth=False),
    "Bambino": dict(mouth=False, cuff="accent", ribs=True, cuff_h=0.3),
    "Jingleo": dict(cuff_h=0.5, face_drop=1.0),
    "Ninjolino": dict(body="#3A3F6E", dark="#1A1B2E", inner="#0F1020", cuff="dark", face_drop=1.12, mood="ninja"),
    "Sockbeard": dict(mouth=False, mood="pirate", cuff="dark",
                      stripes=[(1.0, 1.22, "accent"), (1.45, 1.67, "accent"), (1.9, 2.12, "accent"), (2.35, 2.57, "accent")]),
}
MATERIALS = {
    "PolkaDottie_dot": "knit",
    "Bambino_paci": "plastic",
    "Bambino_duck": "knit",
    "Jingleo_berry": "plastic",
    "Jingleo_snowflake": "decal",
    "Ninjolino_bandage": "fabric",
    "Ninjolino_shuriken": "metal",
    "Ninjolino_headband": "fabric",
    "Sockbeard_skull": "decal",
    "Sockbeard_teeth": "plastic",
    "Sockbeard_eyepatch": "rubber",
}
