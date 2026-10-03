"""
sockfeat_e.py - signature features for Spaghettino, Sockula, Merlino, Sockstrong, Dragonzola, Toetankhamun, Sockfather (the second wave).

Each feature builder takes the SockCtx `c` built by socks.py and returns a list of sockkit Pieces
added on top of the shared body (same rules as sockfeat_a/b/c.py). This module also keeps its types'
rigging (RIG: type id -> fn(R), the same per-type functions rigging.py has for the first wave),
optional colour retunes (SPEC_OVERRIDES) and texture hints (MATERIALS: colour-name pattern -> class,
see texturing.classify).

The Epic-and-up socks, designed in the character sheet's style (the shared body, googly eyes and
ink outline; body colour + darker heel/toe + cuff) with ONE big idea each that reads from any side
and from far away:
  Spaghettino   a proud chef: a tall puffy white toque (a pleated band under a lumpy mushroom top)
                on the rim, the cuff knitted in green-white-red tricolour bands, a big bushy black
                mustachio (two wavy lobes of overlapping puffs, curling up at the ends) over an open
                happy mouth, a red-and-white checked neckerchief knotted at the front, and a silver
                fork tucked into the side of the cuff with a ball of spaghetti twirled round its
                tines, a dab of tomato sauce on top and one strand dangling
  Sockula       a dramatic (friendly) vampire: slicked-back black hair capping the rim with a sharp
                widow's peak, a black band rising from a gold clasp (red medallion) under the chin
                round to the back of the head, a tall flaring stand-up collar (crimson inside) and a
                long black cape with crimson lining and bat-wing points; arched brows, smug lids,
                faint dark under-eyes, a sly smirk with two fangs that opens for a 'bleh!'
  Merlino       a show-off wizard: a tall blue-violet wizard hat (floppy brim, gold band studded with
                pale stars) whose long tip flops forward and ends in a chunky gold star; gold stars
                and pale crescent moons scattered over the sock; extra glints in the eyes
  Sockstrong    a sock astronaut: white-grey suit with orange stripes, a chunky steel helmet ring
                round the cuff with a red-ball antenna, a round blue mission patch, a belt with a
                little control box and a jetpack on the back (two white tanks, orange bands, nozzles)
  Dragonzola    a fire-breathing dragon: a yellow scaly belly of puffy plates, cream ringed horns,
                yellow spikes down the back to the heel, two red bat wings hinged on the back (half
                open), a tail curling from the heel along the floor to a red spade, a toothy grin
  Toetankhamun  a pharaoh mummy: bandage turns round the leg and foot (a loose end trailing), a gold
                nemes with lapis stripes (gold brow band, a little cobra, flaring flaps, two striped
                lappets), a broad bead collar, a long braided gold beard and black eyeliner wings
  Sockfather    the boss of the drawer: charcoal pinstripe suit, grey fedora with a black band, a
                tuxedo front (white shirt V, black lapels, bow tie), a red rose on the lapel, heavy
                lids, a thin moustache and a gold watch chain on the side
Colour borders inside one piece are baked into the texture (at ~0.02 per texel they show pixel steps
on long straight borders), so big two-colour patterns that must stay crisp - the nemes and lappet
stripes, the collar's bead rows - are separate strips laid 0.01 over the base instead.
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import hexcol
import socks as S
from socks import C_GOLD, C_PINKMOUTH, C_TONGUE
from sockfeat_c import _sweep, _lathe, _blob, _ellipsoid, _frame, _rnd, _ink_line, _lids, _fin
from sockfeat_b import _shell, _puck
import rigging
from rigging import Chain

TAU = math.tau
Z = Vector((0.0, 0.0, 1.0))
_lerp, _smooth = S._lerp, S._smooth

FEATURES = {}         # type id -> fn(SockCtx) -> [Piece]
RIG = {}              # type id -> fn(rigging.Rig): extra bones + how the feature pieces are weighted
SPEC_OVERRIDES = {}   # type id -> dict merged over socks.SPECS[type id]
MATERIALS = {}        # colour-name pattern -> texturing class (the longest matching pattern wins)

# colours the spec stripes use must exist before body_pieces() runs (it looks them up by name)
C_SPAG_WHITE = hexcol("Spaghettino_stripe_white", "#FFFFFF")
C_SPAG_RED = hexcol("Spaghettino_extra", "#D9443F")


# ------------------------------------------------------------------ geometry helpers
def _piece(bm, pals, name, outline=True, smooth=True):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pals, outline, smooth, name)


def _dir(a):
    """Unit horizontal direction at angle a round the leg (0 = face -Y, +pi/2 = +X, pi = back)."""
    return Vector((math.sin(a), -math.cos(a), 0.0))


def _rev(profile, pal, seg=24, mat=None, warp=None, pal_fn=None, outline=True, smooth=True, name="rev"):
    """A surface of revolution about local +Z from (r, z) points listed bottom -> top along the
    outside (r = 0 makes a pole), like sockfeat_c._lathe, but every vertex can be moved by
    warp(r, z, phi) -> (r, z) first (puffs, pleats, a pinched crown, a snap brim). pal_fn(k, j,
    centre) colours faces (k = profile segment, j = sector)."""
    bm = bmesh.new()
    rings = []
    for r, z in profile:
        if r <= 1e-6:
            rings.append(bm.verts.new((0.0, 0.0, z)))
            continue
        ring = []
        for j in range(seg):
            ph = TAU * j / seg
            rr, zz = warp(r, z, ph) if warp else (r, z)
            ring.append(bm.verts.new((rr * math.cos(ph), rr * math.sin(ph), zz)))
        rings.append(ring)
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
    bm.normal_update()
    return _piece(bm, pals, name, outline, smooth)


def _tag(piece, **kw):
    """Rig bookkeeping on a piece (rigging.py reads it back from K.PIECE_MAP as R.info['tags'])."""
    piece.rig = {k: ([tuple(p) for p in v] if k == "path" else v) for k, v in kw.items()}
    return piece


def _rows(rows, pal, pole=None, pal_fn=None, closed=True, out_ref=None, outline=True, smooth=True, name="rows"):
    """A surface through rows of points (each row a list of the same length, closed into a ring
    when `closed`), optionally ending in one `pole` point. Faces point away from out_ref(centre)
    (default: away from the leg axis at the face's height). pal_fn(i, k, centre) colours faces
    (i = row gap, k = column)."""
    bm = bmesh.new()
    vr = [[bm.verts.new(Vector(p)) for p in row] for row in rows]
    m = len(rows[0])
    pv = bm.verts.new(Vector(pole)) if pole is not None else None
    pals = []
    ks = range(m) if closed else range(m - 1)
    for i in range(len(vr) - 1):
        for k in ks:
            k2 = (k + 1) % m
            f = bm.faces.new((vr[i][k], vr[i][k2], vr[i + 1][k2], vr[i + 1][k]))
            pals.append(pal_fn(i, k, f.calc_center_median()) if pal_fn else pal)
    if pv is not None:
        for k in ks:
            f = bm.faces.new((vr[-1][k], vr[-1][(k + 1) % m], pv))
            pals.append(pal_fn(len(vr) - 1, k, f.calc_center_median()) if pal_fn else pal)
    bm.normal_update()
    ref = out_ref or (lambda q: Vector((q.x, q.y, 0.0)))
    for f in bm.faces:
        cen = f.calc_center_median()
        if f.normal.dot(ref(cen)) < 0:
            f.normal_flip()
    bm.normal_update()
    return _piece(bm, pals, name, outline, smooth)


def _decal(surf2d, poly, lift, thick, pal, name="decal", outline=False, smooth=False):
    """A flat colour shape conforming to a surface: the 2D polygon `poly` (any winding, may be
    concave) is triangulated and each point mapped by surf2d(x, y) -> (point, normal); the back sits
    `lift` off the surface, the front `thick` further, closed by walls round the outline. No hull."""
    from mathutils.geometry import delaunay_2d_cdt
    nb = len(poly)
    vco, _e, faces, _o, _oe, _of = delaunay_2d_cdt([Vector(p) for p in poly], [], [list(range(nb))], 1, 1e-7)
    bm = bmesh.new()
    front, back, nrm = [], [], []
    for q in vco:
        p, n = surf2d(q.x, q.y)
        front.append(bm.verts.new(p + n * (lift + thick)))
        back.append(bm.verts.new(p + n * lift))
        nrm.append(n)
    count = {}
    for f in faces:
        for i in range(3):
            e = tuple(sorted((f[i], f[(i + 1) % 3])))
            count[e] = count.get(e, 0) + 1
        nn = nrm[f[0]] + nrm[f[1]] + nrm[f[2]]
        for layer, want in ((front, nn), (back, -nn)):
            fc = bm.faces.new([layer[i] for i in f])
            fc.normal_update()
            if fc.normal.dot(want) < 0:
                fc.normal_flip()
    cen2 = sum((Vector(p) for p in poly), Vector((0.0, 0.0))) / nb
    for (i, j), k in count.items():
        if k != 1:
            continue
        fc = bm.faces.new((front[i], front[j], back[j], back[i]))
        fc.normal_update()
        mid = (vco[i] + vco[j]) / 2 - cen2
        p_mid, _n = surf2d((vco[i].x + vco[j].x) / 2, (vco[i].y + vco[j].y) / 2)
        p_in, _n2 = surf2d(cen2.x + mid.x * 0.9, cen2.y + mid.y * 0.9)
        if fc.normal.dot(p_mid - p_in) < 0:
            fc.normal_flip()
    return _piece(bm, pal, name, outline=outline, smooth=smooth)


def _inked_decal(surf2d, poly, pal, ink=0.022, lift=0.012, thick=0.012, name="decal"):
    """_decal on a black one grown `ink` all round (an even ink border, like S._inked)."""
    from sockfeat_a import _offset_poly
    return [_decal(surf2d, _offset_poly(poly, ink), lift, thick, K.BLACK, name=name + "_ink", smooth=True),
            _decal(surf2d, poly, lift + 0.01, thick, pal, name=name)]


def _on_leg(c, a0, z0, spin=0.0):
    """surf2d for decals on the leg round (angle a0, height z0): x round the leg, y up."""
    r0 = c.radius_at(z0, a0)
    cs, sn = math.cos(spin), math.sin(spin)

    def f(x, y):
        x, y = x * cs - y * sn, x * sn + y * cs
        return c.surface(a0 + x / r0, z0 + y)
    return f


def _on_body(c, hit, spin=0.0):
    """surf2d round a surface point hit = (point, normal) anywhere on the body (foot, heel): points
    of its tangent plane cast back onto the body along -normal."""
    p0, n0 = Vector(hit[0]), Vector(hit[1]).normalized()
    e1 = Z.cross(n0)
    e1 = e1.normalized() if e1.length > 1e-4 else Vector((1.0, 0.0, 0.0))
    e2 = n0.cross(e1).normalized()
    cs, sn = math.cos(spin), math.sin(spin)

    def f(x, y):
        x, y = x * cs - y * sn, x * sn + y * cs
        q = p0 + e1 * x + e2 * y
        h_ = c.ray(q + n0 * 0.5, -n0)
        return h_ if h_ else (q, n0)
    return f


def _star_poly(R, inner=0.45, n=5, rot=0.0):
    return [(math.cos(rot + math.pi / 2 + math.pi * k / n) * (R if k % 2 == 0 else R * inner),
             math.sin(rot + math.pi / 2 + math.pi * k / n) * (R if k % 2 == 0 else R * inner)) for k in range(2 * n)]


def _moon_poly(R, m=8):
    """A crescent opening to +x: an outer arc from 50 to 310 degrees, back along a smaller arc."""
    h1 = Vector((math.cos(math.radians(50)), math.sin(math.radians(50)))) * R
    ci = Vector((0.45 * R, 0.0))
    ri = (h1 - ci).length
    a1 = math.atan2(h1.y - ci.y, h1.x - ci.x)
    pts = [(math.cos(math.radians(_lerp(50, 310, k / m))) * R, math.sin(math.radians(_lerp(50, 310, k / m))) * R)
           for k in range(m + 1)]
    for k in range(1, m):
        a = _lerp(TAU - a1, a1, k / m)
        pts.append((ci.x + math.cos(a) * ri, ci.y + math.sin(a) * ri))
    return pts


# ------------------------------------------------------------------ Chef Spaghettino
def feat_spaghettino(c):
    """A proud Italian chef. The toque: a pleated white band round the rim (soft vertical pleats
    with grey grooves) under a big lumpy mushroom top (six puffs round a domed crown) - from far
    away a white cloud on the head. The cuff is the tricolour (green band, white and red stripes:
    SPEC_OVERRIDES). A bushy black mustachio: each lobe three overlapping flattened puffs that grow
    smaller toward the tip and curl up (the hulls ink the scallops), over an open happy mouth with a
    tongue. A red-and-white checked neckerchief round the neck, knotted at the front with two short
    pointed ends. A silver fork tucked into the heel side of the cuff, leaning out, with a ball of
    spaghetti twirled round its tines, a dab of tomato sauce on top and one strand dangling."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    white = hexcol(f"{tid}_hat", "#FCFCFA")
    pleat = hexcol(f"{tid}_hat_pleat", "#DCDDE4")
    stache = hexcol(f"{tid}_stache", "#2A2228")
    scarf_r = hexcol(f"{tid}_scarf", "#D9443F")
    scarf_w = hexcol(f"{tid}_scarf_white", "#FBF6F0")
    fork = hexcol(f"{tid}_fork", "#C9D1DC")
    noodle = hexcol(f"{tid}_noodle", "#F4D47C")
    noodle2 = hexcol(f"{tid}_noodle_dark", "#E2B656")
    sauce = hexcol(f"{tid}_sauce", "#D6362C")
    out = []
    # --- toque: pleated band + puffy mushroom top
    rc = c.top_r + 0.07
    zb0 = h - 0.03
    zb1 = h + 0.42

    def band_warp(r, z, ph):
        if z < zb0 + 0.01 or r < rc - 0.01:
            return r, z
        return r * (1.0 + 0.035 * math.cos(10 * ph)), z

    def band_col(k, j, cen):
        ph = (math.atan2(cen.y, cen.x)) % TAU
        return pleat if math.cos(10 * ph) < -0.55 else white

    prof = [(0.0, h - 0.02), (rc - 0.04, h - 0.02), (rc - 0.04, zb0), (rc, zb0), (rc, _lerp(zb0, zb1, 0.5)),
            (rc, zb1)]
    out.append(_rev(prof, white, seg=40, warp=band_warp, pal_fn=band_col, name="toqueband"))
    R1 = rc + 0.24

    def puff_warp(r, z, ph):
        # six puffs round the crown: the radius swells on each puff and dips between them, the
        # top bulges up over each puff
        lob = math.cos(6 * ph)
        t = _smooth((z - zb1) / 0.25)
        return r * (1.0 + 0.09 * lob * t), z + 0.07 * (0.5 + 0.5 * lob) * _smooth((z - (zb1 + 0.6)) / 0.35)

    top = zb1 + 1.02
    mprof = [(rc - 0.02, zb1 - 0.04), (rc + 0.1, zb1 + 0.02), (R1 - 0.1, zb1 + 0.12), (R1, zb1 + 0.3),
             (R1 + 0.03, zb1 + 0.52), (R1 - 0.03, zb1 + 0.72), (R1 * 0.78, top - 0.1), (R1 * 0.42, top - 0.01),
             (0.0, top + 0.02)]
    out.append(_rev(mprof, white, seg=36, warp=puff_warp, name="toque"))
    c.pin_z = top + 0.12
    # --- moustache: two bushy lobes of overlapping flattened puffs, curling up at the ends
    m_top = c.ey - c.eye_rim_r - 0.07
    mz = m_top - 0.15
    for s in (-1, 1):
        for x, z, rx, rz, rot in ((0.15, 0.0, 0.2, 0.15, -0.15), (0.35, -0.04, 0.17, 0.13, 0.25),
                                  (0.5, 0.04, 0.12, 0.1, 0.9), (0.57, 0.16, 0.08, 0.075, 1.4)):
            p, n = c.face_point(s * x, mz + z, 0.0)
            fr = _frame(n, Z)
            rot_m = fr @ Matrix.Rotation(-s * rot, 4, "Z")
            out.append(_ellipsoid(stache, p + n * 0.02, (rx, rz, 0.075), rot_m, seg=10, rings=6, name="stache"))
    c._stache = (Vector(c.face_point(0.0, mz, 0.0)[0]), mz)
    # --- an open happy mouth under it, with a tongue
    oz = mz - 0.2
    w0, dep = 0.17, 0.15

    def mouth(g):
        w = w0 + g
        return (-w, w, (lambda u: oz + 0.035 * (u / w0) ** 2 + g),
                (lambda u: oz - dep * max(1 - (abs(u) / w) ** 2.2, 0.0) ** 0.6 - g))
    out += S._inked(c.face_point, mouth, C_PINKMOUTH, border=0.032, lift=0.024, n=11, name="mouth")
    tz = oz - dep * 0.62

    out.append(S._plate(c.face_point, [_lerp(-0.075 + 0.02 * d, 0.115 + 0.02 * d, i / 8) for i in range(9)],
                        lambda u: tz + 0.035 * (1 - ((u - 0.02 * d) / 0.1) ** 2),
                        lambda u: oz - dep * max(1 - (abs(u) / w0) ** 2.2, 0.0) ** 0.6 + 0.012,
                        0.03, C_TONGUE, name="tongue"))
    # --- checked neckerchief: a band round the neck, a knot at the front, two pointed ends
    z_top = oz - dep - 0.13
    z_bot = z_top - 0.17
    nu = 32

    def checks(u, v, cen):
        a = math.atan2(cen.x, -cen.y) % TAU
        i = int(a / (TAU / nu))
        k = int(math.floor((cen.z - z_bot) / 0.085))
        return scarf_r if (i + k) % 2 == 0 else scarf_w

    def kband(u, v):
        a = TAU * u
        return a, _lerp(z_bot, z_top, v) - 0.02 * math.cos(a), 0.03

    out.append(_shell(c, nu, 2, kband, 0.05, scarf_r, wrap=True, pal_fn=checks, name="scarf"))
    kp, kn = c.surface(0.0, z_bot + 0.04)
    for s in (-1, 1):
        def end(u, v, s=s):
            a = s * (0.1 + 0.32 * v) + (u - 0.5) * (0.42 - 0.38 * v)
            return a, _lerp(z_bot + 0.06, z_bot - 0.5, v) - 0.04 * abs(u - 0.5), 0.07 + 0.05 * v

        out.append(_shell(c, 4, 4, end, 0.04, scarf_r, pal_fn=checks, name="scarfend"))
    out.append(_puck(kp + kn * 0.11, kn, Z, 0.15, 0.12, 0.13, scarf_r, p=2.2, bevel=0.45, seg=16, rings=2,
                     pal_fn=lambda k, n_, f: scarf_w if (k + int(f.calc_center_median().x * 30)) % 3 == 0 else scarf_r,
                     name="scarfknot"))
    # --- the fork tucked into the heel side of the cuff, leaning out and back, with the twirl
    a_f = -d * math.radians(84.0)
    out_d = _dir(a_f)
    base, bn = c.surface(a_f, h - 0.4)
    lean = math.radians(40.0)
    up = (Z * math.cos(lean) + out_d * math.sin(lean)).normalized()
    p0 = base - bn * 0.08
    p1 = p0 + up * 1.05
    side = up.cross(out_d).normalized()
    out.append(_sweep([p0, p0 + up * 0.55, p1], [0.085, 0.095, 0.11], fork, seg=10, samples=2, cap0=0.0, cap1=0.0,
                      flat=0.5, up=out_d, name="fork"))
    neck = p1 + up * 0.14
    out.append(_sweep([p1 - up * 0.01, neck], [0.1, 0.18], fork, seg=10, samples=2, cap0=0.0, cap1=0.0, flat=0.33,
                      up=out_d, name="fork"))
    for k in range(4):
        x = (k - 1.5) * 0.1
        q0 = neck + side * x
        out.append(_sweep([q0, q0 + up * 0.42], [0.036, 0.03], fork, seg=6, samples=1, cap0=0.0, cap1=1.0,
                          flat=0.7, up=out_d, name="tine"))
    # spaghetti twirl round the tines: a ball of stacked, tilted coils
    tc = neck + up * 0.2
    for k, (rr, dz, tilt, col) in enumerate(((0.25, -0.1, 0.25, noodle), (0.29, -0.02, -0.2, noodle2),
                                              (0.28, 0.07, 0.3, noodle), (0.22, 0.15, -0.15, noodle2))):
        fr = _frame(up, out_d) @ Matrix.Rotation(tilt, 4, "X") @ Matrix.Rotation(k * 1.3, 4, "Z")
        out.append(K.torus(col, rr, 0.07, Matrix.Translation(tc + up * dz) @ fr, seg=16, mseg=6, name="twirl"))
    out.append(_ellipsoid(noodle2, tc + up * 0.02, (0.24, 0.24, 0.18), _frame(up, out_d), seg=12, rings=6,
                          outline=False, name="twirl"))
    sp = tc + up * 0.25 + out_d * 0.04
    out.append(_blob(sauce, sp, _frame(up, out_d).to_3x3(), (0.15, 0.13, 0.09), seg=10, rings=3, cut=-0.2, lump=0.12,
                     seed=3, name="sauce"))
    # the dangling strand: out of the bottom of the twirl, a lazy S hanging down
    s0 = tc - up * 0.13 + out_d * 0.24
    path = [s0, s0 + out_d * 0.08 - Z * 0.2, s0 + out_d * 0.04 - Z * 0.42 + side * 0.05,
            s0 + out_d * 0.1 - Z * 0.64 - side * 0.04, s0 + out_d * 0.07 - Z * 0.84]
    out.append(_tag(_sweep(path, [0.048] * len(path), noodle, seg=6, samples=3, cap0=0.8, cap1=1.0, name="noodle"),
                    path=path))
    c._fork = (p0, neck + up * 0.42)
    return out


def rig_spaghettino(R):
    c = R.c
    rigging._hat(R, "toque toqueband", "Cuff")
    st, mz = c._stache
    R.add("Stache", "Leg4", st, st + Z * 0.3, "spring", hint=dict(wobble=15))
    R.put(R.idx("stache"), ("bone", "Stache"))
    p0, tip = c._fork
    R.add("Fork", "Cuff", p0, tip, "accessory")
    R.put(R.idx("fork tine twirl sauce"), ("bone", "Fork"))
    i = R.idx("noodle")[0]
    path = [Vector(p) for p in R.info["tags"][i]["path"]]
    names = ["Noodle1", "Noodle2"]
    tmp = Chain(path, names, [0, 1, 2], R.base)
    L = tmp.length()
    kn = [0.0, L * 0.45, L]
    ch = Chain(path, names, kn, lambda p: {"Fork": 1.0}, root_blend=(0.02, 0.12))
    R.add("Noodle1", "Fork", ch.at(kn[0]), ch.at(kn[1]), "dangle", index=1, seg=1, hint=dict(swing=35))
    R.add("Noodle2", "Noodle1", ch.at(kn[1]), ch.at(kn[2]), "dangle", index=1, seg=2, hint=dict(swing=35))
    R.put([i], ("chain", ch))
    R.put(R.idx("scarfknot scarfend"), ("stuck", R.cen(R.idx("scarfknot"))))


FEATURES["Spaghettino"] = feat_spaghettino
RIG["Spaghettino"] = rig_spaghettino
# a warmer cream than SPECS (so the white toque and the white stripe stand out from the sock), and
# the tricolour cuff: a green band on top, then a white and a red stripe (the toque covers the lip)
SPEC_OVERRIDES["Spaghettino"] = dict(body="#F7EBD2", dark="#E6D2AA", accent="#3BA55C", extra="#D9443F",
                                     cuff="accent", cuff_h=0.2, ribs=True,
                                     stripes=[(3.88, 4.0, "Spaghettino_stripe_white"),
                                              (3.76, 3.88, "Spaghettino_extra")],
                                     face_drop=0.88, mouth=False)
MATERIALS.update({"Spaghettino_stache": "fur", "Spaghettino_fork": "metal", "Spaghettino_tine": "metal",
                  "Spaghettino_noodle": "plastic", "Spaghettino_sauce": "plastic",
                  "Spaghettino_stripe": "knit"})


# ------------------------------------------------------------------ Count Sockula
def _wrapa(a):
    """An angle folded into -pi..pi."""
    return math.atan2(math.sin(a), math.cos(a))


def feat_sockula(c):
    """A dramatic (friendly) vampire. Slicked-back black hair caps the rim: a smooth glossy dome
    whose hairline runs round under the top and dips into a sharp widow's peak between the eyes,
    a few lighter comb lines running back over it. A black cape with crimson lining: a black band
    round the neck fastened at the front by a gold ring with a red medallion; out of the back of the
    band rises a tall stand-up collar (black outside, crimson inside) that flares out and up behind
    the head into two big points beside the face, and the cape falls down the back from it,
    flaring out toward a hem of bat-wing points (it stays high over the foot). The face: arched
    brows, smug half-lids, faint dark under-eyes, a sly smirk (a thin dark crescent that opens for
    a 'bleh!' - the Jaw) with two little white fangs hanging over the lip."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    hair = hexcol(f"{tid}_hair", "#231E30")
    shine = hexcol(f"{tid}_hair_shine", "#5B5277")
    cape = hexcol(f"{tid}_cape", "#1E1A2B")
    lining = hexcol(f"{tid}_cape_lining", "#B3203A")
    gold = hexcol(f"{tid}_gold", "#F5C842")
    gem = hexcol(f"{tid}_gem", "#D3203F")
    bags = hexcol(f"{tid}_shadow", "#B8AED0")
    out = []
    # --- slicked-back hair: a cap over the rim down to the hairline (widow's peak at the front)
    seg = 40
    eye_top = c.ey + c.eye_rim_r

    def z_edge(a):
        w = abs(_wrapa(a))
        return h - 0.3 - (h - 0.3 - (eye_top + 0.01)) * max(1.0 - w / 0.4, 0.0) ** 1.25

    angs = [TAU * j / seg for j in range(seg)]
    rows = [[c.surface(a, z_edge(a), 0.004)[0] for a in angs], [c.surface(a, z_edge(a), 0.05)[0] for a in angs]]
    for t in (0.3, 0.6, 1.0):
        rows.append([c.surface(a, _lerp(z_edge(a), h - 0.05, t), 0.05 + 0.035 * t)[0] for a in angs])
    for rr, zz in ((c.top_r + 0.075, h + 0.02), (c.top_r * 0.98, h + 0.17), (c.top_r * 0.84, h + 0.31),
                   (c.top_r * 0.58, h + 0.41), (c.top_r * 0.28, h + 0.46)):
        rows.append([_dir(a) * rr + Z * zz for a in angs])
    cap_c = Vector((0.0, 0.0, h - 0.8))
    hair_p = _rows(rows, hair, pole=Vector((0.0, 0.0, h + 0.48)), out_ref=lambda q: q - cap_c, name="hair")
    out.append(hair_p)
    c.pin_z = h + 0.56
    # comb lines running back over the top (ray cast onto the cap from above)
    from sockfeat_c import _bvh
    ray = _bvh([hair_p])
    for k, x0 in enumerate((-0.34, -0.13, 0.1, 0.31)):
        pts, nrms = [], []
        for j in range(9):
            y = _lerp(-c.top_r * 0.82, c.top_r * 0.95, j / 8)
            if j == 0:
                hit = ray((x0, -2.0, z_edge(math.atan2(x0, 0.7)) + 0.06), (0.0, 1.0, 0.0))
            else:
                hit = ray((x0, y, h + 2.0), (0.0, 0.0, -1.0))
            if hit is None:
                continue
            pts.append(hit[0] + hit[1] * 0.008)
            nrms.append(hit[1])
        if len(pts) >= 3:
            out.append(S._ink(pts, nrms, 0.026 if k % 3 else 0.034, samples=2, taper=0.3, pal=shine, name="hairline"))
    # --- arched brows, smug half-lids, faint dark under-eyes
    for i, e in enumerate(c.eyes):
        s = -1.0 if e[0] < 0 else 1.0
        ex, ez = e[0], e[2]
        top = ez + c.eye_rim_r
        pts = [(ex - s * 0.19, top + 0.06), (ex - s * 0.04, top + 0.15), (ex + s * 0.1, top + 0.19),
               (ex + s * 0.25, top + 0.11)]
        hits = [c.face_point(x, z, 0.012) for x, z in pts]
        out.append(S._ink([p for p, _n in hits], [n for _p, n in hits], 0.05, taper=0.35, name="brow"))
        rr = c.eye_rim_r + 0.012
        hw = 0.24
        us = [_lerp(ex - hw, ex + hw, k / 10) for k in range(11)]

        def btop(u, ex=ex, ez=ez):
            return ez - math.sqrt(max(rr * rr - (u - ex) ** 2, 0.0))

        def bbot(u, ex=ex, ez=ez):
            return btop(u) - 0.075 * max(1.0 - ((u - ex) / hw) ** 2, 0.0) ** 0.8
        out.append(S._plate(c.face_point, us, btop, bbot, 0.01, bags, depth=0.02, name="bags"))
    out += _lids(c, c.body, math.radians(98), math.radians(60), lift=0.03, line_r=0.04, clip=0.4)
    # --- a sly smirk: a thin dark crescent rising toward the toe, two fangs over the lower lip
    mz0 = c.mouth_z + 0.02
    w = 0.21

    def mtop(u):
        t = max(-1.0, min(1.0, d * u / w))
        return mz0 + 0.025 * t + 0.03 * t * t

    def mgap(u):
        t = max(-1.0, min(1.0, u / w))
        return 0.05 * max(1.0 - t * t, 0.0) ** 0.7 + 0.004

    def mouth(g):
        ww = w + g
        return (-ww, ww, (lambda u: mtop(u) + g), (lambda u: mtop(u) - mgap(u) - g))
    out += S._inked(c.face_point, mouth, C_PINKMOUTH, border=0.03, lift=0.024, n=13, name="mouth")
    for fx in (-0.085, 0.085):
        z0 = mtop(fx) + 0.005

        def fang(g, fx=fx, z0=z0):
            fw, fl = 0.045 + g, 0.11 + 1.6 * g
            return (fx - fw, fx + fw, (lambda u: z0 + g * 0.5),
                    (lambda u: z0 - fl * (1 - min(abs(u - fx) / fw, 1.0) ** 1.4)))
        out += S._inked(c.face_point, fang, K.WHITE, border=0.022, lift=0.036, n=7, name="fang")
    c._mouth = (mtop, mgap, w)
    # --- the neck band, fastened at the front: a gold ring with a red medallion
    # (it rises from the clasp under the chin round the sides to the back of the head, so the
    # collar and the cape hang from the head block - the Leg4 bone - at the back)
    zf, zk = mz0 - 0.56, c.mouth_z + 0.04

    def band_lo(a):
        return _lerp(zf, zk, (0.5 - 0.5 * math.cos(a)) ** 1.2)

    def nband(u, v):
        a = TAU * u
        return a, band_lo(a) + 0.12 * v, 0.035

    out.append(_shell(c, 36, 1, nband, 0.05, cape, wrap=True, name="neckband"))
    # the clasp: two gold discs either side of a big gold medallion with a red stone, flat on the band
    mz = band_lo(0.0) + 0.04
    mp, mn = c.surface(0.0, mz)
    out.append(_puck(mp + mn * 0.1, mn, Z, 0.2, 0.17, 0.06, gold, p=2.0, bevel=0.35, bulge=0.02, seg=20,
                     name="clasp"))
    out.append(_puck(mp + mn * 0.14, mn, Z, 0.11, 0.09, 0.05, gem, p=2.0, bevel=0.45, bulge=0.025, seg=16,
                     outline=False, name="medallion"))
    for s in (-1, 1):
        q, qn = c.surface(s * 0.48, band_lo(0.48) + 0.06)
        out.append(_puck(q + qn * 0.09, qn, Z, 0.08, 0.08, 0.05, gold, p=2.0, bevel=0.4, seg=12, rings=2,
                         name="clasp"))
    # --- the stand-up collar: out of the back of the band, flaring up and out behind the head
    a_f = math.radians(64.0)

    def csurf(a, z):
        dvec = _dir(a)
        r = c.radius_at(min(z, h - 0.08), a)
        return dvec * r + Z * z, dvec

    def ctop(a):
        f = (abs(_wrapa(a)) - a_f) / (math.pi - a_f)          # 0 at the front points, 1 at the back
        return h + 0.12 - 0.42 * _smooth(f / 0.75) ** 0.8

    def collar(u, v):
        a = math.pi + (u - 0.5) * 2 * (math.pi - a_f)
        f = abs(u - 0.5) * 2                                   # 1 at the front edges
        z = _lerp(band_lo(a) + 0.06, ctop(a), v)
        return a, z, 0.04 + (0.5 + 0.3 * f ** 2) * v ** 1.7

    out.append(_shell(c, 22, 5, collar, 0.05, lining, pal_fn=lambda u, v, cen: cape, surf=csurf, wall_pal=cape,
                      name="collar"))
    # --- the cape down the back: flaring out to a hem of bat-wing points, high over the foot
    rcap = c.RL * 1.08

    def capesurf(a, z):
        dvec = _dir(a)
        p, n = c.surface(a, z)
        if math.hypot(p.x, p.y) > rcap or z < c.instep_z:
            r = min(math.hypot(p.x, p.y), rcap)
            return dvec * r + Z * z, dvec
        return p, (n + dvec).normalized()

    nu = 25

    def cape_at(u, v):
        half = 1.0 + 0.5 * v
        a = math.pi + (u - 0.5) * 2 * half
        toe = math.sin(a) * d                                  # > 0 on the toe side
        z_hem = 0.66 + 0.75 * _smooth((toe - 0.15) / 0.75) + 0.2 * abs(math.sin(math.pi * 5 * u)) ** 0.6
        f = abs(u - 0.5) * 2
        fold = 0.5 - 0.5 * math.cos(TAU * 5 * u)
        lift = 0.035 + 0.36 * v ** 1.5 + 0.09 * fold * v + 0.16 * _smooth((f - 0.75) / 0.25) * v
        return a, _lerp(band_lo(a) + 0.08, z_hem, v), lift

    cape_p = _shell(c, nu, 6, cape_at, 0.045, lining, pal_fn=lambda u, v, cen: cape, surf=capesurf, wall_pal=cape,
                    name="cape")
    out.append(cape_p)
    c._cape = (band_lo, cape_at, capesurf)
    return out


class _CapeWeights:
    """Rig weights for Sockula's cape (one piece, two dangle halves): duck-types rigging.Chain for a
    ("chain", ...) target. Down the cape the head block (Leg4, which the band at the back rides) hands
    over to Cape*_1, then to Cape*_2; across the back the left half (-x, Cape1_*) blends into the
    right half (+x, Cape2_*) over a band round the middle, so the halves swing apart without tearing."""

    def __init__(self, band_lo, z_mid):
        self.band_lo, self.z_mid = band_lo, z_mid

    def arc_of(self, pts):
        return [0.0] * len(pts)

    def weights(self, p, _s):
        z0 = self.band_lo(math.atan2(p[0], -p[1])) + 0.08
        t_root = _smooth((z0 - p[2]) / 0.35)                  # 0 at the band -> 1 below it
        t_seg = _smooth((self.z_mid + 0.2 - p[2]) / 0.4)       # Cape*_1 -> Cape*_2 round z_mid
        right = _smooth((p[0] + 0.18) / 0.36)                  # 0 on the left half, 1 on the right
        w = {}
        for side, share in ((1, 1.0 - right), (2, right)):
            if share <= 0.0:
                continue
            rigging._add(w, f"Cape{side}_1", share * (1.0 - t_seg))
            rigging._add(w, f"Cape{side}_2", share * t_seg)
        return rigging._mix({"Leg4": 1.0}, w, t_root)


def rig_sockula(R):
    c = R.c
    rigging._hat(R, "hair hairline", "Cuff")
    # the jaw: hinged 2 behind the mouth (like PuppetSupreme's) - opening drops the lower edge of the
    # smirk's dark crescent; the fangs stay with the upper lip
    mtop, mgap, w = c._mouth
    top_z = mtop(0.0)
    R.add("Jaw", "Leg4", (0.0, 2.0, top_z - 0.05), (0.0, 2.0, top_z + 0.25), "jaw", hint=dict(turn=6, slide=0.12))
    base = R.base

    def jaw(p):
        x, y, z = p
        fr = _smooth((-y - 0.1) / 0.3)
        if fr <= 0.0:
            return 0.0
        u = max(-w, min(w, x))
        zt, zb = mtop(u), mtop(u) - mgap(u)
        a = min(max((zt - z) / max(zt - zb, 0.004), 0.0), 1.0)
        b = 1.0 - _smooth((zb - 0.06 - z) / 0.22)
        lat = 1.0 - _smooth((abs(x) - (w + 0.02)) / 0.16)
        return a * b * lat * fr

    def field(p):
        j = jaw(p)
        return rigging._mix(base(p), {"Jaw": 1.0}, j) if j > 0.0 else base(p)
    R.field = field
    for i in R.idx("fang fang_ink"):
        R.put([i], ("stuck", R.cen([i]), "base"))
    R.put(R.idx("collar"), ("bone", "Leg4"))
    R.put(R.idx("clasp medallion"), ("stuck", R.cen(R.idx("medallion"))))
    # the cape halves, hanging from the band at the back of the head
    band_lo, cape_at, capesurf = c._cape
    ci = R.idx("cape")
    v = R.verts(ci)
    z_hem = float(v[:, 2].min())
    z_top = band_lo(math.pi) + 0.08
    z_mid = _lerp(z_top, z_hem, 0.45)
    for side, sg in ((1, -1.0), (2, 1.0)):
        a = math.pi - sg * 0.75
        top = capesurf(a, band_lo(a) + 0.08)[0] + _dir(a) * 0.06
        mid = capesurf(a, z_mid)[0] + _dir(a) * 0.25
        hem = capesurf(a, z_hem + 0.15)[0] + _dir(a) * 0.4
        R.add(f"Cape{side}_1", "Leg4", top, mid, "dangle", index=side, seg=1, hint=dict(swing=20))
        R.add(f"Cape{side}_2", f"Cape{side}_1", mid, hem, "dangle", index=side, seg=2, hint=dict(swing=20))
    R.put(ci, ("chain", _CapeWeights(band_lo, z_mid)))


FEATURES["Sockula"] = feat_sockula
RIG["Sockula"] = rig_sockula
SPEC_OVERRIDES["Sockula"] = dict(cuff="body", mouth=False, face_drop=0.92)
MATERIALS.update({"Sockula_hair": "plastic", "Sockula_shadow": "knit", "Sockula_collar": "fabric",
                  "Sockula_gem": "glass", "Sockula_neckband": "fabric"})


# ------------------------------------------------------------------ Merlino Magnifico
def _star3d(ctr, nrm, up, R, depth, pal, inner=0.5, name="star"):
    """A chunky 3D star (a bevelled prism, rounded a little) facing nrm, one point toward `up`."""
    from sockfeat_c import _prism
    fr = _frame(nrm, up)
    return _prism(_star_poly(R, inner), depth, Matrix.Translation(ctr) @ fr, pal, bevel=min(0.035, depth * 0.4),
                  segs=2, name=name)


def feat_merlino(c):
    """A show-off wizard. A tall pointy wizard hat in the sock's blue (a touch more violet): a soft
    floppy brim round the rim, a straight cone that bends over near the top so its long tip flops
    forward (drifting a little toward the toe) and hangs down, ending in a chunky gold star; a gold
    band round the base of the cone studded with small pale stars. The sock is scattered with gold
    stars and pale crescent moons (inked flat decals, none on the face), two on the foot. Big sparkly
    eyes: two extra glints on each googly eye. No beard (that's Sockrates)."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    hat = hexcol(f"{tid}_hat", "#4A44C2")
    band = hexcol(f"{tid}_hat_band", "#F2C14E")
    star = hexcol(f"{tid}_star", "#F7CF57")
    star_pale = hexcol(f"{tid}_star_pale", "#FFF3BF")
    moon = hexcol(f"{tid}_moon", "#FFE9A6")
    out = []
    # --- the brim: a soft round ring with a wavy, drooping edge
    rc = c.top_r + 0.06
    Rb = rc + 0.42

    def brim_warp(r, z, ph):
        f = _smooth((r - rc) / (Rb - rc))
        return r, z + 0.05 * f * math.sin(3 * ph + 0.6) - 0.06 * f * f

    bprof = [(rc - 0.04, h - 0.03), (rc + 0.15, h - 0.06), (Rb - 0.06, h - 0.07), (Rb + 0.02, h - 0.04),
             (Rb, h + 0.0), (Rb - 0.1, h + 0.02), (rc + 0.1, h + 0.06), (rc - 0.04, h + 0.06)]
    out.append(_rev(bprof, hat, seg=28, warp=brim_warp, name="brim"))
    # --- the cone: straight up, then bending forward over and hanging down (one sweep, dense path)
    ctrl = [(0.0, 0.0, h + 0.02), (0.0, 0.0, h + 0.5), (0.0, 0.02, h + 1.0), (0.01 * d, -0.04, h + 1.42),
            (0.07 * d, -0.2, h + 1.68), (0.17 * d, -0.44, h + 1.76), (0.27 * d, -0.66, h + 1.62),
            (0.33 * d, -0.78, h + 1.36), (0.35 * d, -0.8, h + 1.16)]
    P = S._catmull([Vector(p) for p in ctrl], 4)
    acc = [0.0]
    for a_, b_ in zip(P, P[1:]):
        acc.append(acc[-1] + (b_ - a_).length)
    L = acc[-1]
    r0, r_tip = rc - 0.02, 0.065

    def rad(sv):
        return _lerp(r0, r_tip, (sv / L) ** 0.85)

    R_ = [rad(sv) for sv in acc]
    cone = _sweep(P, R_, hat, seg=14, samples=1, cap0=0.0, cap1=0.6, name="hatcone")
    out.append(_tag(cone, path=P))
    # the bend begins where the path leaves the vertical
    s_bend = next(acc[k] for k in range(len(P)) if P[k].z > h + 1.15)
    c._hat = (P, acc, s_bend)
    # --- the gold band round the cone's base, studded with pale stars
    zb0, zb1 = h + 0.1, h + 0.34
    rb0, rb1 = rad(zb0 - h - 0.02) + 0.035, rad(zb1 - h - 0.02) + 0.035
    out.append(_rev([(rb0 - 0.04, zb0 - 0.01), (rb0, zb0), (rb1, zb1), (rb1 - 0.04, zb1 + 0.01)], band, seg=32,
                    name="hatband"))
    zm = (zb0 + zb1) / 2
    rm = (rb0 + rb1) / 2 + 0.008
    slope = math.atan2(rb0 - rb1, zb1 - zb0)
    for k in range(6):
        a = TAU * k / 6 + 0.2
        n = (_dir(a) * math.cos(slope) + Z * math.sin(slope)).normalized()
        out.append(_star3d(_dir(a) * rm + Z * zm, n, Z, 0.085, 0.03, star_pale, inner=0.48, name="bandstar"))
    # --- the gold star on the tip, hanging below it, facing forward
    tip = P[-1]
    tdir = (P[-1] - P[-3]).normalized()
    sc = tip + tdir * (r_tip * 0.6 + 0.2)
    out.append(_star3d(sc, Vector((0.25 * d, -1.0, 0.0)).normalized(), -tdir, 0.25, 0.1, star, inner=0.5,
                       name="tipstar"))
    c.pin_z = h + 1.15
    # --- stars and crescent moons scattered over the sock (inked decals; none on the face)
    for a, z, R, kind, spin in ((0.0, 2.3, 0.2, 0, 0.1), (0.62 * d, 1.86, 0.15, 1, 0.5), (-0.78 * d, 2.55, 0.13, 0, -0.2),
                                (1.35 * d, 3.2, 0.19, 1, -0.4), (-1.5 * d, 3.3, 0.16, 0, 0.3), (2.25 * d, 2.55, 0.17, 0, -0.1),
                                (math.pi, 3.25, 0.2, 1, 0.3), (-2.35 * d, 2.05, 0.16, 0, 0.25), (2.75 * d, 1.7, 0.13, 0, 0.6),
                                (-1.15 * d, 1.75, 0.16, 1, 0.9), (1.9 * d, 1.55, 0.12, 0, 0.0)):
        poly = _star_poly(R, 0.46) if kind == 0 else _moon_poly(R)
        out += _inked_decal(_on_leg(c, a, z, spin * d), poly, star if kind == 0 else moon,
                            name="star" if kind == 0 else "moon")
    for x, y, R, kind, spin in ((1.0, -0.15, 0.16, 0, 0.3), (1.3, 0.25, 0.12, 1, -0.6)):
        hit = c.ray((d * x, y, c.h), (0.0, 0.0, -1.0))
        if hit:
            poly = _star_poly(R, 0.46) if kind == 0 else _moon_poly(R)
            out += _inked_decal(_on_body(c, hit, spin * d), poly, star if kind == 0 else moon,
                                name="star" if kind == 0 else "moon")
    # --- sparkly eyes: two extra glints on each eye
    look = Vector((0.26 * d, -0.46, 1.0)).normalized()
    for i, T in enumerate(c.eye_mats):
        g = []
        for off, ang in (((0.32, -0.3, 0.0), 6.5), ((0.05, 0.42, 0.0), 4.0)):
            gd = (look + Vector(off)).normalized()
            g.append(S._cap(K.WHITE, gd, math.radians(ang), T, lift=0.026, seg=8, rings=1, name="sparkle"))
        S._wrap_pieces(g, c.eye_wrap[i])
        out += g
    return out


def rig_merlino(R):
    ids = rigging._hat(R, "brim hatband bandstar", "Cuff")
    i = R.idx("hatcone")[0]
    path = [Vector(p) for p in R.info["tags"][i]["path"]]
    P, acc, s_bend = R.c._hat
    L = acc[-1]
    names = ["HatTip1", "HatTip2"]
    kn = [s_bend, s_bend + (L - s_bend) * 0.45, L]
    ch = Chain(path, names, kn, lambda p: {"Hat": 1.0}, root_blend=(s_bend - 0.15, s_bend + 0.1))
    hb = R.bones["Hat"]
    hb.tail = ch.at(s_bend)
    R.add("HatTip1", "Hat", ch.at(kn[0]), ch.at(kn[1]), "dangle", index=1, seg=1, hint=dict(swing=30))
    R.add("HatTip2", "HatTip1", ch.at(kn[1]), ch.at(kn[2]), "dangle", index=1, seg=2, hint=dict(swing=30))
    R.put([i], ("chain", ch))
    R.put(R.idx("tipstar"), ("bone", "HatTip2"))
    R.put(R.idx("sparkle"), ("bone", R.eye_parent))
    return ids


FEATURES["Merlino"] = feat_merlino
RIG["Merlino"] = rig_merlino
MATERIALS.update({"Merlino_hat": "felt", "Merlino_hat_band": "metal"})


# ------------------------------------------------------------------ Neil Sockstrong
def feat_sockstrong(c):
    """A sock astronaut in a white-grey suit with orange stripes (the body). A chunky silver helmet
    ring locked round the cuff (a rounded collar with a dark groove and four bolts, standing a little
    above the rim, so a helmet could click on) with a short antenna on the heel side topped by a red
    ball. A round blue mission patch on the toe side of the leg (white ring, a gold star, a red
    swoosh). A small jetpack on the back: two white tanks with orange bands and domed tops on a grey
    back plate, two dark nozzles pointing down, held on by a grey belt round the leg."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    silver = hexcol(f"{tid}_silver", "#A9B4C6")
    silver_d = hexcol(f"{tid}_silver_dark", "#6C7689")
    ball = hexcol(f"{tid}_ball", "#E8433B")
    tank = hexcol(f"{tid}_tank", "#F7F8FA")
    tank_o = hexcol(f"{tid}_tank_band", "#FF8A3D")
    plate = hexcol(f"{tid}_pack", "#7E879A")
    nozzle = hexcol(f"{tid}_nozzle", "#4A4E5C")
    nozzle_in = hexcol(f"{tid}_nozzle_inside", "#24262E")
    patch = hexcol(f"{tid}_patch", "#2F5BD3")
    swoosh = hexcol(f"{tid}_swoosh", "#E8433B")
    out = []
    # --- the helmet ring round the cuff
    R0 = c.top_r + 0.03
    z0, z1 = h - 0.34, h + 0.1
    ring = [(R0 - 0.02, z0 - 0.02), (R0 + 0.06, z0 - 0.03), (R0 + 0.13, z0 + 0.03), (R0 + 0.15, _lerp(z0, z1, 0.35)),
            (R0 + 0.16, _lerp(z0, z1, 0.5)), (R0 + 0.15, _lerp(z0, z1, 0.65)), (R0 + 0.12, z1 - 0.02),
            (R0 + 0.04, z1 + 0.02), (R0 - 0.06, z1), (R0 - 0.08, z1 - 0.12)]
    zg = _lerp(z0, z1, 0.5)
    out.append(_rev(ring, silver, seg=36, name="helmetring",
                    pal_fn=lambda k, j, cen: silver_d if abs(cen.z - zg) < 0.03 else silver))
    for k in range(4):
        a = TAU * k / 4 + math.pi / 4
        p = _dir(a) * (R0 + 0.155) + Z * (zg + 0.11)
        out.append(_ellipsoid(silver_d, p, (0.045, 0.045, 0.03), _frame(_dir(a), Z), seg=8, rings=4, outline=False,
                              name="bolt"))
    # the antenna: a short rod on the heel side, topped by a red ball
    a_a = -d * math.radians(125.0)
    base = _dir(a_a) * (R0 + 0.08) + Z * (z1 - 0.02)
    tip = base + _dir(a_a) * 0.08 + Z * 0.62
    out.append(_lathe([(0.0, -0.04), (0.075, -0.04), (0.08, 0.04), (0.05, 0.1), (0.0, 0.11)], silver_d,
                      seg=10, mat=Matrix.Translation(base), name="antennabase"))
    out.append(_sweep([base, tip], [0.028, 0.022], silver_d, seg=6, samples=1, cap0=0.0, cap1=0.0, name="antenna"))
    out.append(K.sphere(ball, 0.1, Matrix.Translation(tip + (tip - base).normalized() * 0.07), seg=10, rings=6,
                        name="antennaball"))
    c._antenna = (base, tip + (tip - base).normalized() * 0.07)
    # --- mission patch on the toe side: blue disc, white ring, gold star, red swoosh
    a_p, z_p = d * math.radians(60.0), c.mouth_z - 0.3
    srf = _on_leg(c, a_p, z_p)
    disc = [(math.cos(TAU * k / 24) * 0.26, math.sin(TAU * k / 24) * 0.26) for k in range(24)]
    out += _inked_decal(srf, disc, patch, ink=0.03, name="patch")
    ringp = [(math.cos(TAU * k / 24) * 0.215, math.sin(TAU * k / 24) * 0.215) for k in range(24)]
    ringi = [(math.cos(-TAU * k / 24) * 0.18, math.sin(-TAU * k / 24) * 0.18) for k in range(24)]
    out.append(_decal(srf, ringp + [ringp[0], ringi[0]] + ringi, 0.032, 0.006, K.WHITE, name="patchring"))
    out.append(_decal(srf, _star_poly(0.11, 0.45), 0.034, 0.008, C_GOLD, name="patchstar"))
    sw = [(math.cos(t) * 0.23 - 0.02, math.sin(t) * 0.08 - 0.05) for t in [math.pi * k / 8 for k in range(9)]]
    sw += [(math.cos(t) * 0.21 - 0.02, math.sin(t) * 0.045 - 0.05) for t in [math.pi * (8 - k) / 8 for k in range(9)]]
    out.append(_decal(srf, sw, 0.036, 0.006, swoosh, name="patchswoosh"))
    # --- the jetpack on the back
    zt0, zt1 = 2.05, 3.05
    yb = c.radius_at((zt0 + zt1) / 2, math.pi)
    tanks = []
    for s in (-1, 1):
        cx = s * 0.25
        y = yb + 0.26
        P0 = Vector((cx, y, zt0))
        Lt = zt1 - zt0
        prof = [(0.0, 0.0), (0.17, 0.0), (0.22, 0.05), (0.22, 0.17), (0.22, 0.27), (0.22, 0.7), (0.22, 0.8),
                (0.22, 0.92), (0.18, 1.0), (0.1, 1.05), (0.0, 1.07)]
        out.append(_lathe([(r, z * Lt) for r, z in prof], tank, seg=16, mat=Matrix.Translation(P0),
                          pal_fn=lambda k, j, cen: tank_o if k in (3, 6) else tank, name="tank"))
        # nozzle: a dark bell under the tank, tilted back a little
        ndir = Vector((0.0, 0.25, -1.0)).normalized()
        q = P0 + Vector((0.0, 0.0, 0.02))
        fr = _frame(-ndir, Vector((0.0, 1.0, 0.0)))
        out.append(_lathe([(0.07, 0.0), (0.09, -0.08), (0.14, -0.2), (0.15, -0.24), (0.1, -0.22), (0.0, -0.18)],
                          nozzle, seg=14, mat=Matrix.Translation(q) @ fr,
                          pal_fn=lambda k, j, cen: nozzle_in if k >= 3 else nozzle, name="nozzle"))
        tanks.append((q - fr.to_3x3() @ Vector((0.0, 0.0, 0.24)), ndir))
    c._jets = tanks
    # the back plate between the tanks and the back
    def back(u, v):
        a = math.pi + (u - 0.5) * 0.95
        return a, _lerp(zt0 + 0.08, zt1 - 0.1, v), 0.02

    out.append(_shell(c, 6, 4, back, 0.12, plate, name="packplate"))
    # the belt holding it on
    def belt(u, v):
        a = TAU * u
        return a, _lerp(2.22, 2.34, v), 0.02

    out.append(_shell(c, 32, 1, belt, 0.045, plate, wrap=True, name="belt"))
    # a control box on the front of the belt: three coloured buttons
    bp, bn = c.surface(0.0, 2.28)
    out.append(_puck(bp + bn * 0.1, bn, Z, 0.21, 0.15, 0.12, silver, p=3.0, bevel=0.3, seg=20, name="panel"))
    for k, col in enumerate((ball, C_GOLD, patch)):
        q, qn = c.surface((k - 1) * 0.16, 2.28)
        out.append(_puck(q + qn * 0.17, qn, Z, 0.045, 0.045, 0.04, col, p=2.0, bevel=0.4, seg=10, rings=2,
                         outline=False, name="button"))
    c._pack_z = (zt0, zt1)
    return out


def rig_sockstrong(R):
    c = R.c
    rigging._hat(R, "helmetring bolt antennabase", "Cuff")
    base, top = c._antenna
    R.add("Antenna", "Hat", base, top, "spring", hint=dict(wobble=30))
    R.put(R.idx("antenna antennaball"), ("bone", "Antenna"))
    R.put(R.idx("tank nozzle packplate"), ("bone", "Leg3"))
    order = sorted(range(2), key=lambda k: c._jets[k][0].x)
    for i, k in enumerate(order):
        p, nd = c._jets[k]
        R.add(f"Jet{i + 1}", "Leg3", p, p + nd * 0.3, "jet", index=i + 1)
    R.put(R.idx("patch patch_ink patchring patchstar patchswoosh"), ("stuck", R.cen(R.idx("patch"))))
    R.put(R.idx("panel button"), ("stuck", R.cen(R.idx("panel"))))


FEATURES["Sockstrong"] = feat_sockstrong
RIG["Sockstrong"] = rig_sockstrong
SPEC_OVERRIDES["Sockstrong"] = dict(face_drop=0.92)     # the brave brows clear the helmet ring
MATERIALS.update({"Sockstrong_tank": "plastic", "Sockstrong_pack": "plastic", "Sockstrong_nozzle": "metal",
                  "Sockstrong_ball": "plastic", "Sockstrong_patch": "fabric", "Sockstrong_swoosh": "fabric"})


# ------------------------------------------------------------------ Dragonzola
def _wing_poly(s=1.0):
    """A bat wing in its own plane: x out from the hinge (x = 0, the back), y up. Shoulder at the
    top of the hinge, the arm rising out to the wrist, three fingers spreading out and down, the
    membrane between them scalloped in toward the wrist. -> (outline, wrist, finger tips, shoulder,
    hinge bottom)."""
    S_, Wr = Vector((0.0, 0.32)), Vector((0.5, 0.84))
    F = [Vector((1.16, 0.62)), Vector((1.06, 0.06)), Vector((0.66, -0.3))]
    B = Vector((0.0, -0.34))
    pts = []

    def arc(a, b, sag, n=5, first=True):
        """a -> b bowing `sag` toward the wrist (a scallop) - endpoints a (if first), not b."""
        mid = (a + b) / 2
        toward = (Wr - mid).normalized()
        for k in range(0 if first else 1, n):
            t = k / n
            q = a.lerp(b, t) + toward * (sag * math.sin(math.pi * t))
            pts.append(q)

    arc(S_, Wr, -0.08, 4)                    # the leading edge bows out (up) a little
    pts.append(Wr + Vector((0.05, 0.06)))     # the thumb claw point
    arc(Wr + Vector((0.08, 0.02)), F[0], -0.04, 4)
    arc(F[0], F[1], 0.17, 5)
    arc(F[1], F[2], 0.15, 5)
    arc(F[2], B, 0.13, 5)
    arc(B, S_, 0.0, 3)
    return [(q.x, q.y) for q in pts], Wr, F, S_, B


def _spade_poly(L=0.36, W=0.3):
    """A spade (the dragon's tail tip) in 2D: pointing +x, its stem at the origin."""
    pts = []
    for k in range(13):
        t = math.pi * k / 12 - math.pi / 2           # round lobes at the back, a point at the front
        r = 0.5 + 0.5 * math.cos(t) ** 0.6
        pts.append((L * 0.35 + math.cos(t) * L * 0.65 * r, math.sin(t) * W * 0.5 * (1.0 + 0.6 * math.cos(t) ** 3)))
    pts.append((0.06, -0.06))
    pts.append((0.06, 0.06))
    pts = [pts[-1]] + pts[:-1]
    return pts


def feat_dragonzola(c):
    """A fire-breathing dragon sock. Orange, with a yellow scaly belly down the front under the face
    (a stack of puffy rounded plates, each inked, narrowing toward the instep), two cream ringed
    horns on the rim curving up and back, a row of yellow spikes from the cuff down the back to the
    heel, two red bat wings on the back, half open (a pillowy membrane scalloped between three
    fingers, darker red finger ribs and arm, a cream thumb claw), a fat tail out of the heel that
    curls back along the floor with a few small spikes and a red spade tip. Face: two nostrils
    and a toothy grin (a white zig-zag row of teeth with two little fangs at the corners)."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    belly = hexcol(f"{tid}_belly", "#FFD15C")
    spike = hexcol(f"{tid}_spike", "#FFC93E")
    horn = hexcol(f"{tid}_horn", "#F6E7C3")
    horn2 = hexcol(f"{tid}_horn_ring", "#D9C397")
    wing = hexcol(f"{tid}_wing", "#C9362C")
    rib = hexcol(f"{tid}_wing_rib", "#8E1F1F")
    mouth_in = hexcol(f"{tid}_mouth", "#7E1C24")
    out = []
    # --- belly plates down the front
    z_top = c.mouth_z - 0.27
    z_bot = 1.12
    n = 5
    gap = 0.035
    step = (z_top - z_bot) / n
    for k in range(n):
        za, zb = z_top - k * step, z_top - (k + 1) * step + gap
        half = _lerp(0.62, 0.48, k / (n - 1))

        def plate(u, v, za=za, zb=zb, half=half):
            a = (u - 0.5) * 2 * half * (1.0 - 0.1 * (1 - v))
            return a, _lerp(zb, za, v), 0.012 + 0.045 * math.sin(math.pi * v) ** 0.7 * math.sin(math.pi * u) ** 0.5

        out.append(_shell(c, 8, 3, plate, 0.03, belly, name="belly"))
    # --- horns: ringed cones on the rim, curving up and back
    for s in (-1, 1):
        b = Vector((s * 0.48, 0.06, h - 0.1))
        pts = [b, b + Vector((s * 0.1, 0.0, 0.3)), b + Vector((s * 0.2, 0.14, 0.55)), b + Vector((s * 0.22, 0.38, 0.7)),
               b + Vector((s * 0.2, 0.6, 0.68))]
        out.append(_sweep(pts, [0.19, 0.155, 0.11, 0.07, 0.03], horn, seg=10, samples=3, cap0=0.0, cap1=0.8,
                          pal_fn=lambda sv, ph, cen: horn2 if 0.2 < (sv * 5.0) % 1.0 < 0.38 and sv < 0.75 else horn,
                          name="horn"))
    # --- spikes down the back to the heel
    spikes = []
    for k, (z, da, sz) in enumerate(((h - 0.32, 0.0, 0.5), (h - 0.84, 0.0, 0.52), (h - 1.36, 0.08, 0.5),
                                     (h - 1.88, 0.2, 0.46), (h - 2.38, 0.42, 0.42), (h - 2.82, 0.75, 0.36))):
        a = math.pi + d * da
        p, nn = c.surface(a, z)
        spikes.append(_fin(spike, p, nn, -Z, sz, sz * 0.95, 0.075, lean=0.3, name="spike"))
    hp = c.heel_point
    if hp:
        spikes.append(_fin(spike, hp[0], hp[1], Vector(c.heel_dir).cross(Vector((0.0, d, 0.0))) * -1.0, 0.27, 0.25,
                           0.06, lean=0.3, name="spike"))
    out += spikes
    # --- wings: hinged on the back either side of the spikes, half open
    poly, Wr, F, S_, B = _wing_poly()
    ws = 1.4
    poly = [(x * ws, y * ws) for x, y in poly]
    Wr, F, S_, B = Wr * ws, [f * ws for f in F], S_ * ws, B * ws
    zc = 3.02
    wings = []
    for s in (-1, 1):
        a_h = math.pi - s * 0.36
        hp_, hn = c.surface(a_h, zc)
        Wv = Vector((s * 0.72, 0.69, 0.0)).normalized()
        up = Vector((0.0, 0.12, 1.0)).normalized()
        up = (up - Wv * up.dot(Wv)).normalized()
        nrm = Wv.cross(up).normalized()
        o = hp_ - hn * 0.02

        def wpt(x, y, o=o, Wv=Wv, up=up):
            return o + Wv * x + up * y

        def wsurf(x, y, nrm=nrm, wpt=wpt):
            return wpt(x, y) - nrm * 0.022, nrm          # the membrane's mid-plane is the wing plane

        out.append(_decal(wsurf, poly, 0.0, 0.044, wing, name="wing", outline=True, smooth=True))
        for tip_, r in ((F[0], 0.032), (F[1], 0.03), (F[2], 0.028)):
            m_ = Wr.lerp(tip_, 0.5) + (Wr - tip_).orthogonal().normalized() * 0.03
            out.append(_sweep([wpt(Wr.x, Wr.y), wpt(m_.x, m_.y), wpt(tip_.x, tip_.y)], [r * 1.4, r * 1.1, r * 0.7], rib,
                              seg=6, samples=3, cap0=0.8, cap1=0.8, outline=False, name="wingrib"))
        out.append(_sweep([wpt(S_.x, S_.y), wpt(0.3, 0.86), wpt(Wr.x, Wr.y)], [0.06, 0.056, 0.05], rib, seg=8,
                          samples=3, cap0=0.8, cap1=0.8, name="wingarm"))
        cl = wpt(Wr.x + 0.03, Wr.y + 0.04)
        out.append(_sweep([cl, cl + up * 0.15 + Wv * 0.06], [0.05, 0.014], horn, seg=6, samples=1, cap0=0.8,
                          cap1=0.6, name="claw"))
        wings.append((s, wpt(B.x, B.y), wpt(S_.x, S_.y)))
    c._wings = wings
    # --- the tail: out of the heel, down to the floor and curling back, a red spade at the tip
    hc, hd = Vector(c.heel_c), Vector(c.heel_dir)
    root = hc + hd * (c.heel_radii.x * 0.45)
    path = [root, hc + hd * (c.heel_radii.x + 0.12), Vector((-d * 1.32, 0.1, 0.24)), Vector((-d * 1.72, 0.45, 0.13)),
            Vector((-d * 1.78, 0.92, 0.13)), Vector((-d * 1.5, 1.2, 0.16))]
    tail = _sweep(path, [0.21, 0.19, 0.15, 0.12, 0.1, 0.075], c.body, seg=10, samples=4, cap0=0.0, cap1=0.6,
                  name="tail")
    out.append(_tag(tail, path=S._catmull([Vector(p) for p in path], 4)))
    tp = S._catmull([Vector(p) for p in path], 4)
    tdir = (tp[-1] - tp[-3]).normalized()
    tn = tdir.cross(Z).normalized()
    if tn.z < 0:
        tn = -tn
    tup = tn.cross(tdir).normalized()
    tip = tp[-1] - tdir * 0.04

    def ssurf(x, y):
        return tip + tdir * x + tup * y - tn * 0.025, tn

    out.append(_decal(ssurf, _spade_poly(0.56, 0.5), 0.0, 0.05, c.extra(), name="spade", outline=True, smooth=True))
    for f, sz in ((0.3, 0.2), (0.5, 0.17), (0.7, 0.14)):
        k = int(f * (len(tp) - 1))
        q, t_ = tp[k], (tp[k + 1] - tp[k - 1]).normalized()
        nup = (Z - t_ * Z.dot(t_)).normalized()
        rr = _lerp(0.19, 0.09, f)
        out.append(_fin(spike, q + nup * rr * 0.9, nup, t_, sz, sz * 0.85, 0.05, lean=0.3, name="tailspike"))
    c._tail = tp
    # --- face: nostrils and a toothy grin with two little fangs
    for s in (-1, 1):
        p, nn = c.face_point(s * 0.075, c.mouth_z + 0.17, 0.0)
        out.append(_ellipsoid(K.BLACK, p + nn * 0.004, (0.038, 0.026, 0.014),
                              _frame(nn, Z) @ Matrix.Rotation(-s * 0.5, 4, "Z"), seg=8, rings=4, outline=False,
                              name="nostril"))
    mz = c.mouth_z + 0.03
    w = 0.31

    def gtop(u):
        return mz + 0.07 * (u / w) ** 2

    def gbot(u):
        return gtop(u) - 0.2 * max(1.0 - (abs(u) / w) ** 2, 0.0) ** 0.75

    def grin(g):
        ww = w + g
        return (-ww, ww, (lambda u: gtop(u * w / ww) + g), (lambda u: gbot(u * w / ww) - g))
    out += S._inked(c.face_point, grin, mouth_in, border=0.032, lift=0.022, n=15, name="mouth")
    tw = 0.042
    us = [_lerp(-0.25, 0.25, k / 24) for k in range(25)]
    out.append(S._plate(c.face_point, us, lambda u: gtop(u) + 0.004,
                        lambda u: gtop(u) - 0.035 - 0.035 * abs(((u + 0.25) / tw) % 2.0 - 1.0), 0.03, K.WHITE,
                        name="teeth"))
    for fx in (-0.22, 0.22):
        z0 = gtop(fx)

        def fang(g, fx=fx, z0=z0):
            fw, fl = 0.04 + g, 0.13 + 1.6 * g
            return (fx - fw, fx + fw, (lambda u: z0 + g * 0.5),
                    (lambda u: z0 - fl * (1 - min(abs(u - fx) / fw, 1.0) ** 1.3)))
        out += S._inked(c.face_point, fang, K.WHITE, border=0.02, lift=0.034, n=7, name="fang")
    return out


def rig_dragonzola(R):
    c = R.c
    R.put(R.idx("horn"), ("bone", "Cuff"))
    R.put(R.idx("spike"), ("stuck", None))
    for i, (s, b, t) in enumerate(sorted(c._wings, key=lambda w: w[0])):
        name = f"Wing{i + 1}"
        R.add(name, "Leg4", b, t, "wing", index=i + 1, hint=dict(flap=40))
        R.put(R.idx("wing wingrib wingarm claw", where=lambda q, s=s: q.x * s > 0), ("bone", name))
    i = R.idx("tail")[0]
    path = [Vector(p) for p in R.info["tags"][i]["path"]]
    names = ["Tail1", "Tail2", "Tail3"]
    tmp = Chain(path, names, [0, 1, 2, 3], R.base)
    L = tmp.length()
    s0 = 0.18
    kn = [s0, s0 + (L - s0) * 0.3, s0 + (L - s0) * 0.62, L]
    ch = Chain(path, names, kn, R.base, root_blend=(s0 - 0.12, s0 + 0.08))
    for j in range(3):
        R.add(names[j], "Foot" if j == 0 else names[j - 1], ch.at(kn[j]), ch.at(kn[j + 1]), "dangle", index=1,
              seg=j + 1, hint=dict(swing=25))
    R.put([i] + R.idx("tailspike"), ("chain", ch))
    R.put(R.idx("spade"), ("bone", "Tail3"))
    R.put(R.idx("nostril"), ("bone", "Leg4"))


FEATURES["Dragonzola"] = feat_dragonzola
RIG["Dragonzola"] = rig_dragonzola
SPEC_OVERRIDES["Dragonzola"] = dict(mouth=False)
MATERIALS.update({"Dragonzola_wing": "felt", "Dragonzola_belly": "painted", "Dragonzola_spike": "plastic",
                  "Dragonzola_horn": "ceramic"})


# ------------------------------------------------------------------ King Toetankhamun
def feat_toetankhamun(c):
    """A pharaoh mummy. The cream sock is wrapped in bandage strips - closed bands round the leg and
    the foot, each tilted its own way (a little uneven), alternating two creams, an ink line along
    each one's lower edge where it lies over the next - with a loose end trailing from the back. On
    top a gold-and-lapis striped nemes headdress: a cap over the rim that drops into wide flaring
    side flaps behind the face, a gold band across the forehead with a small gold cobra rearing up
    in the middle, and two striped lappets hanging down either side of the face. A broad collar
    of gold, turquoise and lapis rows (a scalloped bead edge) round the neck under the face, a long
    gold braided pharaoh beard hanging from the chin over it, thick black eyeliner wings."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    wrap1 = hexcol(f"{tid}_wrap", "#F3EBD6")
    wrap2 = hexcol(f"{tid}_wrap_dark", "#DCCDAA")
    gold = hexcol(f"{tid}_gold", "#F2C14E")
    gold2 = hexcol(f"{tid}_gold_dark", "#C9922E")
    ngold = hexcol(f"{tid}_nemes_gold", "#F2C552")
    nblue = hexcol(f"{tid}_nemes_blue", "#2E5AAC")
    turq = hexcol(f"{tid}_turquoise", "#3CC4B4")
    lapis = hexcol(f"{tid}_lapis", "#2E5AAC")
    out = []
    ey, rim = c.ey, c.eye_rim_r
    # --- the nemes: cap + flaring side flaps, striped gold / lapis
    seg = 36
    z_front = h - 0.3
    z_flap = ey - 0.5

    def side_f(a):
        w = abs(_wrapa(a))
        return _smooth((w - math.radians(56.0)) / math.radians(20.0))   # 0 over the face, 1 on the flaps

    def back_f(a):
        return _smooth((abs(_wrapa(a)) - math.radians(115.0)) / math.radians(50.0))

    def z_edge(a):
        return _lerp(z_front, z_flap, side_f(a)) + 0.12 * back_f(a)

    def flare(a, z):
        t = min(max((z_front - z) / (z_front - z_flap), 0.0), 1.0)
        return 0.05 + 0.5 * t ** 1.3 * side_f(a) * (1.0 - 0.55 * back_f(a))

    n_st = 9

    angs = [TAU * j / seg for j in range(seg)]
    rows = [[c.surface(a, z_edge(a), 0.004)[0] for a in angs], [c.surface(a, z_edge(a), flare(a, z_edge(a)))[0] for a in angs]]
    for t in [k / n_st for k in range(1, n_st + 1)]:
        rr = []
        for a in angs:
            z = _lerp(z_edge(a), h - 0.05, t)
            rr.append(c.surface(a, z, flare(a, z))[0])
        rows.append(rr)
    for r_, z_ in ((c.top_r + 0.08, h + 0.04), (c.top_r * 0.86, h + 0.15), (c.top_r * 0.5, h + 0.21)):
        rows.append([_dir(a) * r_ + Z * z_ for a in angs])
    cap_c = Vector((0.0, 0.0, h - 1.2))
    out.append(_rows(rows, ngold, pole=Vector((0.0, 0.0, h + 0.23)), out_ref=lambda q: q - cap_c, name="nemes"))
    # the lapis stripes: separate strips just over the gold (a colour border baked into the texture
    # would show the texture's pixel steps; a geometric edge stays crisp)
    m = len(angs)

    def vnormal(r, k):
        du = rows[r][(k + 1) % m] - rows[r][(k - 1) % m]
        dv = rows[min(r + 1, len(rows) - 1)][k] - rows[max(r - 1, 1)][k]
        n = du.cross(dv).normalized()
        return n if n.dot(rows[r][k] - cap_c) > 0 else -n

    for i in range(2, n_st + 1, 2):
        strip = [[rows[r][k] + vnormal(r, k) * 0.012 for k in range(m)] for r in (i, i + 1)]
        out.append(_rows(strip, nblue, out_ref=lambda q: q - cap_c, outline=False, name="nemesstripe"))
    c.pin_z = h + 0.3
    # the gold band across the forehead, round to the flaps
    def fband(u, v):
        a = (u - 0.5) * 2 * math.radians(64.0)
        return a, z_front + 0.01 + v * 0.13, 0.05

    out.append(_shell(c, 16, 1, fband, 0.04, gold, name="nemesband"))
    # the cobra rearing up in the middle of the band
    bp, bn = c.surface(0.0, z_front + 0.08)
    q0 = bp + bn * 0.08
    cob = [q0, q0 + Z * 0.16 + bn * 0.04, q0 + Z * 0.3 - bn * 0.01, q0 + Z * 0.4 + bn * 0.06]
    out.append(_sweep(cob, [0.06, 0.055, 0.045, 0.04], gold, seg=8, samples=3, cap0=0.6, cap1=0.6, name="cobra"))
    hood = q0 + Z * 0.29
    out.append(_ellipsoid(gold, hood, (0.14, 0.17, 0.04), _frame(bn, Z), seg=12, rings=6, name="cobra"))
    out.append(_ellipsoid(lapis, hood + bn * 0.035, (0.075, 0.11, 0.02), _frame(bn, Z), seg=10, rings=4,
                          outline=False, name="cobrahood"))
    out.append(_ellipsoid(gold, q0 + Z * 0.43 + bn * 0.08, (0.065, 0.055, 0.075), _frame(bn, Z), seg=8, rings=5,
                          name="cobra"))
    # lappets: striped bands hanging down either side of the face, in front of the flaps
    lapp = []
    for s in (-1, 1):
        a0 = s * math.radians(76.0)
        z0, z1 = ey + 0.12, c.mouth_z - 0.32

        def lap(u, v, a0=a0, z0=z0, z1=z1):
            a = a0 + (u - 0.5) * 0.36 * (1.0 + 0.25 * v)
            return a, _lerp(z0, z1, v), 0.16 + 0.06 * v

        out.append(_shell(c, 4, 7, lap, 0.05, ngold, name="lappet"))
        for k in range(1, 7, 2):
            strip = []
            for v in (k / 7, (k + 1) / 7):
                row = []
                for j in range(5):
                    a, z, lf = lap(j / 4, v)
                    p, n = c.surface(a, z)
                    row.append(p + n * (lf + 0.05 + 0.012))
                strip.append(row)
            out.append(_rows(strip, nblue, closed=False, outline=False, name="lappetstripe"))
        lapp.append((s, c.surface(a0, z0, 0.2)[0], c.surface(a0, z1, 0.25)[0]))
    c._lappets = lapp
    # --- eyeliner wings: a thick stroke from the outer corner of each eye, flicking up
    for e in c.eyes:
        s = -1.0 if e[0] < 0 else 1.0
        ex, ez = e[0], e[2]
        # a thick underline hugging the lower outer rim, running on past the outer corner into a
        # long wing that flicks up round the side of the face
        pts = [(ex + s * math.cos(math.radians(ang)) * (rim + 0.015), ez + math.sin(math.radians(ang)) * (rim + 0.015))
               for ang in (-115, -80, -50, -22)]
        pts += [(ex + s * (rim + 0.08), ez - 0.06), (ex + s * (rim + 0.17), ez + 0.03), (ex + s * (rim + 0.22), ez + 0.12)]
        hits = [c.face_point(x, z, 0.014) for x, z in pts]
        out.append(S._ink([p for p, _n in hits], [n for _p, n in hits], 0.05, taper=0.35, samples=2, name="liner"))
    # --- the broad collar: rows of gold, turquoise, gold, lapis, gold and a scalloped bead edge
    zc0 = c.mouth_z - 0.16
    zc1f, zc1b = c.mouth_z - 0.66, c.mouth_z - 0.46
    nv = 3

    def collar(u, v):
        a = TAU * u
        front = 0.5 + 0.5 * math.cos(a)
        zb = _lerp(zc1b, zc1f, front) + 0.05 * abs(math.sin(math.pi * 9 * u))
        return a, _lerp(zc0, zb, v), 0.03 + 0.09 * v

    def ccol(u, v, cen):
        if v > 1.0 - 1.0 / nv:
            return turq if int(u * 18) % 2 else lapis
        return gold

    out.append(_shell(c, 36, nv, collar, 0.05, gold, wrap=True, pal_fn=ccol, wall_pal=gold2, name="collar"))
    for (v0, v1), pal_ in (((0.09, 0.22), turq), ((0.38, 0.5), lapis), ((0.56, 0.62), turq)):
        strip = []
        for v in (v0, v1):
            row = []
            for k in range(36):
                a, z, lf = collar(k / 36, v)
                p, n = c.surface(a, z)
                row.append(p + n * (lf + 0.05 + 0.01))
            strip.append(row)
        out.append(_rows(strip, pal_, outline=False, name="collarrow"))
    # --- the pharaoh beard: a long braided gold column from the chin, standing off the collar
    bt, bn2 = c.surface(0.0, c.mouth_z - 0.12)
    btop = bt + bn2 * 0.04
    bpath = [btop, btop + Vector((0.0, -0.1, -0.3)), btop + Vector((0.0, -0.18, -0.62)),
             btop + Vector((0.0, -0.26, -0.84)), btop + Vector((0.0, -0.36, -0.9))]
    out.append(_sweep(bpath, [0.12, 0.125, 0.135, 0.125, 0.08], gold, seg=12, samples=3, cap0=0.4, cap1=0.6,
                      flat=0.7, up=Vector((0.0, -1.0, 0.0)),
                      pal_fn=lambda sv, ph, cen: gold2 if int(sv * 9 + abs(ph - 0.5) * 1.4) % 2 else gold,
                      name="beard"))
    c._beard = (btop, bpath[-1])
    # --- bandage strips round the leg and the foot
    def band(z_mid, width, tilt, phase, pal, surf=None, nu=22):
        """One bandage turn: an open strip round the leg (its back faces would be hidden anyway):
        its lower edge stands out from the turn below (a black edge wall and a thin ink strip along
        the bottom), its top edge tucks in under the turn above."""
        surf = surf or c.surface
        rows = []
        for v, lift in ((0.0, 0.004), (0.0, 0.042), (0.12, 0.04), (1.0, 0.014)):
            row = []
            for k in range(nu):
                a = TAU * k / nu
                p, n = surf(a, z_mid + tilt * math.sin(a + phase) + (v - 0.5) * width)
                row.append(p + n * lift)
            rows.append(row)
        ctr = [Vector((0.0, 0.0, z_mid))]
        if surf is not c.surface:
            o = surf(0.0, z_mid)[0]
            ctr = [o - surf(0.0, z_mid)[1] * 0.5]
        cref = ctr[0]
        return [_rows(rows, pal, pal_fn=lambda i, k, cen: K.BLACK if i < 2 else pal, outline=False,
                      out_ref=(None if surf is c.surface else (lambda q: q - cref)), name="bandage")]

    zs = []
    z = zc1f + 0.02
    k = 0
    while z > 1.5:
        zs.append((z, 0.05 + 0.04 * _rnd(k, 1), 0.7 + 2.0 * _rnd(k, 2), wrap1 if k % 2 == 0 else wrap2))
        z -= 0.21
        k += 1
    for z, tilt, ph, pal in zs:
        out += band(z, 0.25, tilt, ph, pal)
    if c.d:
        from sockfeat_c import _foot_point

        for j, (t, tilt, ph) in enumerate(((0.47, 0.04, 0.6), (0.64, 0.05, 2.1), (0.8, 0.04, 3.7))):
            def fsurf(a, tt, t=t):
                hit = _foot_point(c, tt, a)
                if hit is None:
                    return _foot_point(c, t, a) or (Vector(c.toe_c), Z)
                return hit
            out += band(t, 0.13, tilt * 0.6, ph, wrap1 if j % 2 else wrap2, surf=fsurf, nu=20)
    # the loose end trailing from the back
    a_l = math.pi - d * 0.35
    z_l = zs[min(2, len(zs) - 1)][0] - 0.1
    lp = [c.surface(a_l, z_l, 0.04)[0], c.surface(a_l + d * 0.12, z_l - 0.28, 0.14)[0],
          c.surface(a_l + d * 0.3, z_l - 0.55, 0.32)[0], c.surface(a_l + d * 0.42, z_l - 0.8, 0.5)[0],
          c.surface(a_l + d * 0.5, z_l - 0.98, 0.66)[0]]
    nrm0 = c.surface(a_l, z_l)[1]
    out.append(_tag(_sweep(lp, [0.11, 0.11, 0.105, 0.1, 0.1], wrap1, seg=8, samples=3, cap0=0.0, cap1=0.0, flat=0.14,
                           up=nrm0, name="looseend"), path=S._catmull([Vector(p) for p in lp], 3)))
    c._loose = lp
    return out


def rig_toetankhamun(R):
    c = R.c
    rigging._hat(R, "nemes nemesstripe nemesband cobra cobrahood", "Cuff")
    for i, (s, top, bot) in enumerate(sorted(c._lappets, key=lambda t: t[0])):
        name = f"Lappet{i + 1}"
        R.add(name, "Hat", top, bot, "dangle", index=i + 1, seg=1, hint=dict(swing=25))
        ids = R.idx("lappet lappetstripe", where=lambda q, s=s: q.x * s > 0)
        tmp = Chain([top, bot], [name], [0.0, (bot - top).length], lambda p: {"Hat": 1.0},
                    root_blend=(0.0, 0.18))
        R.put(ids, ("chain", tmp))
    btop, bend = c._beard
    R.add("Beard", "Leg4", btop, bend, "accessory")
    R.put(R.idx("beard"), ("bone", "Beard"))
    i = R.idx("looseend")[0]
    path = [Vector(p) for p in R.info["tags"][i]["path"]]
    names = ["Wrap1", "Wrap2"]
    tmp = Chain(path, names, [0, 1, 2], R.base)
    L = tmp.length()
    s0 = 0.08
    kn = [s0, s0 + (L - s0) * 0.45, L]
    ch = Chain(path, names, kn, R.field, root_blend=(0.0, s0 + 0.06))
    R.add("Wrap1", R.dominant(ch.at(s0)), ch.at(kn[0]), ch.at(kn[1]), "dangle", index=3, seg=1, hint=dict(swing=20))
    R.add("Wrap2", "Wrap1", ch.at(kn[1]), ch.at(kn[2]), "dangle", index=3, seg=2, hint=dict(swing=20))
    R.put([i], ("chain", ch))


FEATURES["Toetankhamun"] = feat_toetankhamun
RIG["Toetankhamun"] = rig_toetankhamun
MATERIALS.update({"Toetankhamun_wrap": "fabric", "Toetankhamun_nemes": "fabric", "Toetankhamun_beard": "metal",
                  "Toetankhamun_turquoise": "ceramic", "Toetankhamun_lapis": "ceramic", "Toetankhamun_cobra": "metal"})


# ------------------------------------------------------------------ The Sockfather
def feat_sockfather(c):
    """The boss of the drawer. A charcoal pinstripe suit (thin light lines all round the leg, none
    on the face), a grey fedora with a black band on the rim (a snap brim dipping at the front and
    turned up at the back, a creased crown pinched at the front, tilted a touch toward the heel),
    a tuxedo front under the face (a white shirt V between black satin lapels, two shirt studs, a
    black bow tie at the top), a red rose pinned on the toe-side lapel, heavy half-lidded eyes, a
    thin black moustache over the smirk and a gold watch chain looping on the heel side."""
    tid, h, d = c.tid, c.h, (c.d or 1.0)
    felt = hexcol(f"{tid}_hat", "#8D8F9C")
    felt_d = hexcol(f"{tid}_hat_shade", "#73768A")
    band = hexcol(f"{tid}_hat_band", "#1C1A22")
    lapel = hexcol(f"{tid}_lapel", "#1A1820")
    shirt = hexcol(f"{tid}_shirt", "#F7F6F2")
    stripe = hexcol(f"{tid}_stripe", "#8E8D9E")
    rose = hexcol(f"{tid}_rose", "#D3203F")
    rose_d = hexcol(f"{tid}_rose_dark", "#9E1530")
    leaf = hexcol(f"{tid}_leaf", "#3E8E4A")
    gold = hexcol(f"{tid}_gold", "#F2C14E")
    out = []
    # --- pinstripes all round the leg (the front ones only below the shirt's V)
    z_v = 1.86
    for k in range(18):
        a = TAU * k / 18 + 0.17
        front = abs(_wrapa(a)) < 1.05
        z0, z1 = 1.55, (z_v - 0.05 if front else h - 0.42)
        if front and abs(_wrapa(a)) > 0.75:
            z1 = c.mouth_z - 0.5
        n = max(2, int((z1 - z0) / 0.3) + 1)
        pts, nrms = [], []
        for j in range(n + 1):
            p, nn = c.surface(a, _lerp(z0, z1, j / n), 0.008)
            pts.append(p)
            nrms.append(nn)
        out.append(S._ink(pts, nrms, 0.014, flat=0.4, seg=4, samples=1, pal=stripe, name="pinstripe"))
    # --- tuxedo front: the shirt V between black satin lapels
    z_t = c.mouth_z - 0.24
    r0 = c.radius_at(z_t)

    def half(z):
        return 0.4 * _smooth((z - z_v) / (z_t - z_v)) ** 0.8

    def shirt_g(u, v):
        z = _lerp(z_v, z_t, v)
        return (u - 0.5) * 2 * (half(z) + 0.02) / r0, z, 0.012

    out.append(_shell(c, 6, 6, shirt_g, 0.02, shirt, outline=False, name="shirt"))
    for s in (-1, 1):
        def lap(u, v, s=s):
            z = _lerp(z_v - 0.08, z_t + 0.03, v)
            notch = 0.06 * _smooth((v - 0.8) / 0.15)
            inner = half(z) - 0.01 + notch
            w = _lerp(0.14, 0.3, v) - notch
            return s * (inner + u * w) / r0, z, 0.03

        out.append(_shell(c, 3, 7, lap, 0.03, lapel, name="lapel"))
    for k, z in enumerate((z_t - 0.36, z_t - 0.62)):
        p, nn = c.surface(0.0, z, 0.035)
        out.append(_ellipsoid(K.BLACK, p, (0.035, 0.035, 0.015), _frame(nn, Z), seg=8, rings=3, outline=False,
                              name="stud"))
    # bow tie at the top of the V
    bp, bn = c.surface(0.0, z_t - 0.04)
    bc = bp + bn * 0.08
    fr = _frame(bn, Z)
    for s in (-1, 1):
        rot = fr @ Matrix.Rotation(s * 0.12, 4, "Z")
        out.append(_ellipsoid(lapel, bc + fr.to_3x3() @ Vector((s * 0.15, 0.0, -0.02)), (0.14, 0.095, 0.05), rot,
                              seg=10, rings=6, name="bowtie"))
    out.append(_ellipsoid(lapel, bc + bn * 0.03, (0.06, 0.07, 0.05), fr, seg=8, rings=5, name="bowtie"))
    # --- the rose on the toe-side lapel
    a_r = d * (half(z_t - 0.3) + 0.15) / r0
    rp, rn = c.surface(a_r, z_t - 0.3, 0.06)
    rfr = _frame(rn, Z)
    R3 = rfr.to_3x3()
    for k in range(2):
        lv = R3 @ Vector((d * (0.12 + 0.06 * k), -0.12 - 0.04 * k, -0.02))
        out.append(_ellipsoid(leaf, rp + lv, (0.1, 0.05, 0.025), rfr @ Matrix.Rotation(d * (-0.6 - 0.6 * k), 4, "Z"),
                              seg=8, rings=4, name="roseleaf"))
    for k in range(5):
        ang = TAU * k / 5 + 0.3
        pv = R3 @ Vector((math.cos(ang) * 0.085, math.sin(ang) * 0.085, 0.02))
        out.append(_ellipsoid(rose, rp + pv, (0.09, 0.07, 0.05), rfr @ Matrix.Rotation(ang, 4, "Z"), seg=8, rings=5,
                              name="rose"))
    out.append(_ellipsoid(rose_d, rp + rn * 0.06, (0.07, 0.07, 0.05), rfr, seg=10, rings=5, name="rose"))
    out.append(K.torus(rose, 0.045, 0.022, Matrix.Translation(rp + rn * 0.1) @ rfr, seg=10, mseg=5, outline=False,
                       name="rosecurl"))
    c._rose = (rp, rn)
    # --- heavy half-lidded eyes, a thin moustache over the smirk
    out += _lids(c, c.body, math.radians(94), math.radians(76), lift=0.03, line_r=0.042, clip=0.35)
    mz = c.mouth_z + 0.11
    for s in (-1, 1):
        pts = [(s * 0.03, mz + 0.0), (s * 0.12, mz + 0.018), (s * 0.22, mz + 0.0), (s * 0.28, mz - 0.025)]
        out.append(_ink_line(c, pts, radius=0.024, taper=0.35, name="tash"))
    # --- gold watch chain looping on the heel side
    a0, a1 = -d * 1.05, -d * 1.75
    zc = z_t - 0.55
    pts = []
    for k in range(9):
        t = k / 8
        a = _lerp(a0, a1, t)
        z = zc - 0.32 * math.sin(math.pi * t)
        pts.append(c.surface(a, z, 0.05 + 0.04 * math.sin(math.pi * t))[0])
    out.append(_sweep(pts, [0.026] * len(pts), gold, seg=6, samples=2, cap0=0.0, cap1=0.0, name="watchchain"))
    for a in (a0, a1):
        p, nn = c.surface(a, zc, 0.05)
        out.append(_ellipsoid(gold, p, (0.05, 0.05, 0.03), _frame(nn, Z), seg=8, rings=4, name="chainclip"))
    # --- the fedora
    rc = c.top_r + 0.06
    Rb = rc + 0.44
    tilt = (Matrix.Translation((0.0, 0.0, h - 0.14)) @ Matrix.Rotation(math.radians(-7.0) * d, 4, "Y")
            @ Matrix.Rotation(math.radians(-4.0), 4, "X"))
    hc = 0.78

    def hat_warp(r, z, ph):
        sn, cs = math.sin(ph), math.cos(ph)
        if z < 0.13 and r > rc + 0.01:                       # the brim: snap down at the front, up at the back
            f = (r - rc) / (Rb - rc)
            return r, z + f * (0.09 * sn + 0.06 * cs * cs) + 0.03 * f * f
        if z > 0.13:                                        # the crown: pinched at the front, creased on top
            up = _smooth((z - 0.3) / (hc - 0.3))
            fr_ = max(0.0, -sn) ** 2
            r2 = r * (1.0 - 0.14 * up * fr_ * (1.0 - abs(cs)) - 0.06 * up)
            dent = 0.13 * _smooth(1.0 - r / (rc * 0.75)) * (1.0 - 0.6 * abs(cs))
            return r2, z - dent
        return r, z

    prof = [(rc - 0.03, -0.01), (rc + 0.05, -0.02), (Rb - 0.05, 0.0), (Rb, 0.025), (Rb - 0.02, 0.06),
            (rc + 0.12, 0.07), (rc + 0.02, 0.1), (rc, 0.16), (rc - 0.01, 0.3), (rc - 0.03, hc - 0.12),
            (rc * 0.8, hc - 0.02), (rc * 0.5, hc + 0.0), (rc * 0.2, hc - 0.02), (0.0, hc - 0.05)]
    out.append(_rev(prof, felt, seg=36, mat=tilt, warp=hat_warp,
                    pal_fn=lambda k, j, cen: felt_d if k in (4, 5) else felt, name="fedora"))
    out.append(_rev([(rc - 0.02, 0.1), (rc + 0.02, 0.1), (rc + 0.015, 0.27), (rc - 0.03, 0.28)], band, seg=36,
                    mat=tilt, warp=hat_warp, name="hatband"))
    c.pin_z = (tilt @ Vector((0.0, 0.0, hc))).z + 0.05
    return out


def rig_sockfather(R):
    c = R.c
    rigging._hat(R, "fedora hatband", "Cuff")
    rp, rn = c._rose
    parent = R.dominant(rp)
    R.add("Rose", parent, rp, rp + rn * 0.3, "accessory")
    R.put(R.idx("rose roseleaf rosecurl"), ("bone", "Rose"))
    R.put(R.idx("bowtie"), ("stuck", R.cen(R.idx("bowtie"))))
    R.put(R.idx("chainclip"), ("stuck", None))


FEATURES["Sockfather"] = feat_sockfather
RIG["Sockfather"] = rig_sockfather
SPEC_OVERRIDES["Sockfather"] = dict(body="#4D4C58", dark="#353440", cuff="body")
MATERIALS.update({"Sockfather_lapel": "fabric", "Sockfather_stripe": "knit", "Sockfather_rose": "felt",
                  "Sockfather_bowtie": "fabric"})
