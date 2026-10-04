"""
items/bananapeel.py - the BananaPeel item (ReplicatedStorage.ItemMeshes.BananaPeel) and its golden
version BananaPeel_Gold: a cartoon banana peel lying flat on the floor, the trap a player drops. See
items/__init__.py for the conventions, items/defencekit.py for the shared helpers.

A plump, softly five-ridged yellow nub in the middle (where the peel's strips still hang together)
with a short, chunky five-sided stem leaning out of it (a darker collar where it meets the nub, a
flared dark cut end on top); four wide floppy peel strips splay out from low on the nub onto the
floor, yellow side up, their edges arched down and their rounded ends rolling up, so the pale inside
of the peel shows along the rims and under each end; the strips taper to soft points. Painted on:
ripe brown speckles (clustered, two shades), two faint ridge lines down each strip, a glossy
highlight streak.
Each strip is one closed sweep (a rounded cross-section along a centre line that leaves the nub,
drops onto the floor and rolls up in an arc at the end); tone bands are cut along iso-lines of the
surface normal (clean curved borders).

The golden one: the same peel in polished gold (champagne-gold inside), the speckles become little
faceted gems and glitter stars, the ridge lines are engraved, a gem sits near every strip's tip, a
ring of gems round the stem's collar and a big ruby set in the stem's cut end.

1 unit = 1 stud: about 1.7 x 1.8 (2.1 tip to tip), 0.58 tall. Origin = floor centre (the peel rests on it, `_Base`);
`_Grip` = the middle of the stem (the hand holds it by the stem while dropping it; the game turns
it for holding).

The skeleton (`rig`, the same for both): `Root` at the floor centre (unweighted); `Stem` (child of
Root) from the floor centre straight up through the stem's tip: the nub, the stem and everything on
them ride it rigidly; `Flap1`...`Flap4` (children of Root), one per strip in PETALS order (headings
-22, 64, 150, 244 degrees: Flap1 points front-right, then clockwise seen from above: right-back,
back-left, left-front), each from where its strip leaves the nub straight out along the floor to its
tip (head -> tail = local +Y outward, local +Z = up, so turning a Flap about its local +X lifts the
strip, negative presses it down). Every strip blends from Stem (inside the nub) to its Flap over a
short band where it leaves the nub, so a lifted strip peels smoothly off the nub. `POSES` holds
preview.py's test poses.
"""
import math

import bmesh
from mathutils import Vector

import items
import sockkit as K
from sockkit import hexcol
from items import defencekit as DK

NAME = "BananaPeel"

# texture classes (tools/blender/texturing.py): the skin gets the leaf pattern (fibres running along
# each strip), the pale inside a soft paper fibre; the golden one is metal with glassy gems
MATERIALS = {"bananapeel_skin": "leaf", "bananapeel_inside": "paper", "bananapeel_spot": "leaf",
             "bananapeel_stem": "leaf", "bananapeel_cut": "rubber", "bananapeel_ridge": "leaf",
             "bananapeel_gloss": "decal", "bananapeel_gold": "metal", "bananapeel_gem": "glass",
             "bananapeel_sparkle": "decal", "bananapeel_gold_gloss": "decal", "bananapeel_gold_shine": "decal"}


def _palette(gold):
    """Registers this item's palette colours (called by build(), never at import: a colour registered
    when the module is imported would take a palette cell ahead of the socks', see items/__init__.py).
    -> {part: colour or tones}."""
    P = {"gold": gold}
    if not gold:
        P["skin"] = (hexcol("bananapeel_skin_light", "#FFE866"), hexcol("bananapeel_skin", "#FFCB2B"),
                     hexcol("bananapeel_skin_dark", "#E9A11B"), hexcol("bananapeel_skin_deep", "#BF7A17"))
        P["inside"] = (hexcol("bananapeel_inside_light", "#FFFBD8"), hexcol("bananapeel_inside", "#FFF1AE"),
                       hexcol("bananapeel_inside_dark", "#FCE38E"))
        P["spot"] = (hexcol("bananapeel_spot", "#8A5426"), hexcol("bananapeel_spot_light", "#B47A2E"))
        P["stem"] = (hexcol("bananapeel_stem_light", "#C9C452"), hexcol("bananapeel_stem", "#9AA034"),
                     hexcol("bananapeel_stem_dark", "#6F7A24"))
        P["collar"] = hexcol("bananapeel_stem_collar", "#7E7A2A")
        P["cut"] = (hexcol("bananapeel_cut", "#4E3218"), hexcol("bananapeel_cut_rim", "#7A5428"))
        P["ridge"] = hexcol("bananapeel_ridge", "#E8A81E")
        P["gloss"] = hexcol("bananapeel_gloss", "#FFF8C8")
    else:
        G = DK.gold_colours("bananapeel")
        P.update(G)
        P["skin"] = G["gold"]
        P["inside"] = (hexcol("bananapeel_gold_inside_light", "#FFFCEB"), hexcol("bananapeel_gold_inside", "#FBE7AE"),
                       hexcol("bananapeel_gold_inside_dark", "#E8C67A"), hexcol("bananapeel_gold_inside_deep", "#C9A060"))
        P["stem"] = G["gold"][:3]
        P["collar"] = G["gold"][3]
        P["cut"] = (G["gold"][2], G["gold"][1])
        P["ridge"] = hexcol("bananapeel_gold_engrave", "#C98418")
        P["gloss"] = hexcol("bananapeel_gold_gloss", "#FFFBE6")
    return P


TONE_CUTS = (-0.35, 0.78)     # normal z: shade / base / lit
OUTLINE_W = 0.034
# the nub: the still-whole bottom of the peel, (radius, z) bottom to top, five soft ridges round it
NUB = [(0.0, 0.0), (0.235, 0.0), (0.255, 0.06), (0.245, 0.15), (0.2, 0.235), (0.135, 0.29), (0.065, 0.318), (0.0, 0.325)]
RIDGE = 0.075                 # how deep the nub's five ridges are
STEM_PATH = [(0.0, 0.0, 0.24), (0.0, 0.005, 0.35), (0.035, 0.045, 0.44), (0.1, 0.1, 0.5)]
STEM_R = [0.098, 0.09, 0.086, 0.096]   # its (five-sided) half width along the path; flared at the cut
GRIP = (0.0, 0.03, 0.42)

# (heading in degrees from the front -Y toward +X, length from the centre, half width, how far the end
#  rolls up (radians), sideways sway): four strips, a little irregular so the peel looks dropped, not placed
PETALS = [(-22.0, 1.07, 0.215, 0.85, 0.08), (64.0, 0.99, 0.205, 1.05, -0.07), (150.0, 1.05, 0.21, 1.35, 0.07),
          (244.0, 1.01, 0.205, 1.15, -0.09)]
CURL_AT = 0.6                 # the strip lies flat up to here, then its end rolls up
THICK = 0.028                 # half thickness of a strip
ARCH = 0.06                   # how far a strip's edges droop below its middle
LIFT = 0.1                    # how high a strip leaves the nub
FLAP_IN, FLAP_OUT = 0.16, 0.36   # each strip blends from Stem to its Flap between these radii


def _skin(P, nz, part="skin"):
    """The yellow side's (or the inside's) tone; the golden one: polished metal banding."""
    return DK.metal_tone(P[part], nz) if P["gold"] else _tone(P[part], nz)


def _tone(cols, nz):
    if nz > TONE_CUTS[1]:
        return cols[0]
    if nz > TONE_CUTS[0] or len(cols) < 3:
        return cols[1]
    if nz > -0.8 or len(cols) < 4:
        return cols[2]
    return cols[3]


def _dirs(ang):
    return Vector((math.sin(ang), -math.cos(ang), 0.0)), Vector((math.cos(ang), math.sin(ang), 0.0))


def _petal_frame(ang, length, curl, sway, t):
    """Centre point, tangent, side and up of a strip at t (0 = inside the nub, 1 = the tip)."""
    d, side = _dirs(ang)
    span = length - 0.06

    def centre(s):
        flat = min(s, CURL_AT)
        r = 0.06 + span * flat
        z = THICK + ARCH + LIFT * (1.0 - DK.smooth(0.05, 0.45, flat))   # leaves the nub, flops onto the floor
        if s > CURL_AT:   # ... then the end rolls up in an arc (`curl` radians), its pale inside facing out
            rc = (1.0 - CURL_AT) * span / curl
            phi = (s - CURL_AT) / (1.0 - CURL_AT) * curl
            r += rc * math.sin(phi)
            z += rc * (1.0 - math.cos(phi))
        return d * r + side * (sway * math.sin(math.pi * s)) + Vector((0, 0, z))
    c = centre(t)
    tan = (centre(min(1.0, t + 0.01)) - centre(max(0.0, t - 0.01))).normalized()
    s = (side - tan * tan.dot(side)).normalized()   # the strip only bends up / down: its side stays put
    up = tan.cross(s)
    return c, tan, s, up


def _width(w, t):
    """Strip half width: narrower under the nub, widest past the middle, a soft pointed end."""
    k = 0.62 + 0.38 * DK.smooth(0.0, 0.45, t)
    if t > 0.5:
        k *= max(0.0, 1.0 - ((t - 0.5) / 0.5) ** 1.6) ** 0.7   # tapering to a soft point
    return w * k


def _thick(t):
    return THICK * (1.0 - 0.4 * DK.smooth(0.75, 1.0, t))


def _surface(spec, t, a, top=True):
    """Point and normal on a strip's top (or underside) at t along, a (-1..1) across."""
    ang_deg, length, width, curl, sway = spec
    c, _tan, s, up = _petal_frame(math.radians(ang_deg), length, curl, sway, t)
    w = _width(width, t)
    ca = max(-1.0, min(1.0, a))
    sa = math.sqrt(max(0.0, 1.0 - ca * ca)) * (1.0 if top else -1.0)
    p = c + s * (ca * w) + up * (sa * _thick(t) - ARCH * ca * ca * (w / width))
    # the normal: across the rounded section (good enough for laying decals flat on it)
    n = (up * (sa if abs(sa) > 1e-3 else 1e-3) + s * (ca * 0.35)).normalized()
    return p, n


def _petal(P, spec, rows=18, ring=14):
    ang_deg, length, width, curl, sway = spec
    ang = math.radians(ang_deg)
    bm = bmesh.new()
    side_val = {}
    rings = []
    for i in range(rows):   # rings up to just short of the tip (closer together there), which is a single point
        t = 1.0 - (1.0 - i / rows) ** 1.6
        c, _tan, s, up = _petal_frame(ang, length, curl, sway, t)
        w = max(_width(width, t), 0.012)
        th = _thick(t)
        r = []
        for j in range(ring):
            a = j / ring * math.tau
            ca, sa = math.cos(a), math.sin(a)
            v = bm.verts.new(c + s * (ca * w) + up * (sa * th - ARCH * ca * ca * (w / width)))
            side_val[v] = sa
            r.append(v)
        rings.append(r)
    for i in range(rows - 1):
        a, b = rings[i], rings[i + 1]
        for j in range(ring):
            k = (j + 1) % ring
            bm.faces.new((a[j], a[k], b[k], b[j]))
    cen = sum((v.co for v in rings[0]), Vector()) / ring   # the end buried in the nub: a flat cap
    tip = _petal_frame(ang, length, curl, sway, 1.0)[0]    # the other end: a soft point
    for r, cv, sign in ((rings[0], bm.verts.new(cen), 1), (rings[-1], bm.verts.new(tip), -1)):
        side_val[cv] = 0.0
        for j in range(ring):
            k = (j + 1) % ring
            bm.faces.new((cv, r[k], r[j]) if sign > 0 else (cv, r[j], r[k]))
    DK.outward(bm)
    top = bm.faces.layers.int.new("top")
    for f in bm.faces:
        f[top] = 1 if sum(side_val[v] for v in f.verts) / len(f.verts) > 0 else 0
    bm.normal_update()
    nz = {v: (DK.metal_value(v.normal) if P["gold"] else v.normal.z) for v in bm.verts}
    DK.iso_cut(bm, nz, DK.GOLD_CUTS if P["gold"] else TONE_CUTS)
    pal = []
    for f in bm.faces:
        n = sum(nz[v] for v in f.verts) / len(f.verts)
        pal.append(_skin(P, n, "skin" if f[top] else "inside"))
    return DK.piece(bm, pal, "petal", outline=False)


def _petal_hull(spec, rows=15, ring=12):
    """A coarser, uncut copy of a strip for the outline hull only (the hull needs no colour cuts)."""
    ang_deg, length, width, curl, sway = spec
    ang = math.radians(ang_deg)
    bm = bmesh.new()
    rings = []
    for i in range(rows):
        t = 1.0 - (1.0 - i / rows) ** 1.6
        c, _tan, s, up = _petal_frame(ang, length, curl, sway, t)
        w = max(_width(width, t), 0.012)
        th = _thick(t)
        rings.append([bm.verts.new(c + s * (math.cos(a) * w) + up * (math.sin(a) * th - ARCH * math.cos(a) ** 2 * (w / width)))
                      for a in (j / ring * math.tau for j in range(ring))])
    for i in range(rows - 1):
        for j in range(ring):
            k = (j + 1) % ring
            bm.faces.new((rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]))
    cen = bm.verts.new(sum((v.co for v in rings[0]), Vector()) / ring)
    tip = bm.verts.new(_petal_frame(ang, length, curl, sway, 1.0)[0])
    for j in range(ring):
        k = (j + 1) % ring
        bm.faces.new((cen, rings[0][k], rings[0][j]))
        bm.faces.new((tip, rings[-1][j], rings[-1][k]))
    DK.outward(bm)
    return DK.piece(bm, K.OUTLINE, "petal_hull")


def _profile(pts, n):
    """Catmull-Rom through the (r, z) points -> n + 1 points (ends kept)."""
    out = []
    k = len(pts) - 1
    for i in range(n + 1):
        u = i / n * k
        j = min(int(u), k - 1)
        t = u - j
        p0, p1, p2, p3 = (Vector(pts[min(max(m, 0), k)]) for m in (j - 1, j, j + 1, j + 2))
        out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                          + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    return out


def _nub_r(q, a):
    return q.x * (1.0 + RIDGE * math.cos(5 * a + 0.3) * DK.smooth(0.0, 0.1, q.y))


def _nub(P, seg=25):
    bm = bmesh.new()
    rings = []
    for q in _profile(NUB, 12):
        if q.x < 1e-6:
            rings.append([bm.verts.new((0.0, 0.0, q.y))])
            continue
        ring = []
        for j in range(seg):
            a = j / seg * math.tau
            r = _nub_r(q, a)
            ring.append(bm.verts.new((r * math.cos(a), r * math.sin(a), q.y)))
        rings.append(ring)
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        for j in range(seg):
            k = (j + 1) % seg
            if len(a) == 1:
                bm.faces.new((a[0], b[k], b[j]))
            elif len(b) == 1:
                bm.faces.new((a[j], a[k], b[0]))
            else:
                bm.faces.new((a[j], a[k], b[k], b[j]))
    DK.outward(bm)
    bm.normal_update()
    nz = {v: (DK.metal_value(v.normal) if P["gold"] else v.normal.z) for v in bm.verts}
    DK.iso_cut(bm, nz, DK.GOLD_CUTS if P["gold"] else TONE_CUTS)
    pal = [_skin(P, sum(nz[v] for v in f.verts) / len(f.verts)) for f in bm.faces]
    return DK.piece(bm, pal, "nub")


def _nub_point(a, z):
    """Point and outward normal on the nub at heading a (radians round +Z from +X) and height z."""
    prof = _profile(NUB, 40)
    for q0, q1 in zip(prof, prof[1:]):
        if q0.y <= z <= q1.y:
            t = (z - q0.y) / max(q1.y - q0.y, 1e-9)
            q = q0.lerp(q1, t)
            r = _nub_r(q, a)
            d = q1 - q0
            n = Vector((math.cos(a) * d.y, math.sin(a) * d.y, -d.x)).normalized()
            return Vector((r * math.cos(a), r * math.sin(a), z)), n
    return Vector((0, 0, z)), Vector((0, 0, 1))


def _stem(P, gold):
    """A short chunky five-sided stem (soft corners) leaning a little back, flared at the cut end."""
    path = [Vector(p) for p in STEM_PATH]
    bm = bmesh.new()
    seg, rows = 15, 9
    rings = []
    for i in range(rows):
        u = i / (rows - 1) * (len(path) - 1)
        j = min(int(u), len(path) - 2)
        t = u - j
        c = path[j].lerp(path[j + 1], t)
        rr = STEM_R[j] + (STEM_R[j + 1] - STEM_R[j]) * t
        ax = (path[j + 1] - path[j]).normalized()
        x = Vector((1, 0, 0))
        x = (x - ax * x.dot(ax)).normalized()
        y = ax.cross(x)
        ring = []
        for k in range(seg):
            a = k / seg * math.tau
            r = rr * (1.0 + 0.12 * math.cos(5 * a))          # five soft corners
            ring.append(bm.verts.new(c + (x * math.cos(a) + y * math.sin(a)) * r))
        rings.append(ring)
    for i in range(rows - 1):
        for k in range(seg):
            m = (k + 1) % seg
            bm.faces.new((rings[i][k], rings[i][m], rings[i + 1][m], rings[i + 1][k]))
    bot = bm.verts.new(path[0] - Vector((0, 0, 0.02)))
    top = bm.verts.new(path[-1] + (path[-1] - path[-2]).normalized() * 0.004)
    for k in range(seg):
        m = (k + 1) % seg
        bm.faces.new((bot, rings[0][m], rings[0][k]))
        bm.faces.new((top, rings[-1][k], rings[-1][m]))
    DK.outward(bm)
    bm.normal_update()
    key = Vector((-0.5, -0.45, 0.74)).normalized()
    pal = []
    cut_z = path[-1].z - 0.004
    for f in bm.faces:
        if f.calc_center_median().z > cut_z and f.normal.z > 0.6:
            pal.append(P["cut"][0])
        elif f.normal.dot(key) > 0.45:
            pal.append(P["stem"][0])
        elif f.normal.dot(key) < -0.35:
            pal.append(P["stem"][2])
        else:
            pal.append(P["stem"][1])
    out = [DK.piece(bm, pal, "stem")]
    # the collar where the stem meets the nub: a darker soft band
    collar = K.torus(P["collar"], 0.098, 0.026, K.M((0, 0.004, 0.292)), seg=20, mseg=6, outline=False, name="collar")
    out.append(collar)
    # the cut end: a lighter rim ring round the dark cut (the golden one: a big ruby set in it)
    ax = (path[-1] - path[-2]).normalized()
    if gold:
        out.append(DK.gem(P["ruby"], path[-1] + ax * 0.002, ax, 0.068, 0.05, facets=5, sink=0.4, name="gem_ruby"))
    else:
        ring = []
        for k in range(10):
            a = k / 10 * math.tau
            ring.append((0.062 * math.cos(a), 0.062 * math.sin(a)))
        inner = [(x * 0.68, y * 0.68) for x, y in ring]
        out.append(DK.flat_poly(P["cut"][1], ring, path[-1], ax, lift=0.002, name="cut_rim"))
        out.append(DK.flat_poly(P["cut"][0], inner, path[-1], ax, lift=0.004, name="cut"))
    return out


# speckles per strip: (strip, t, a, size, ellipse, spin, light?) - clustered toward the outer part
SPOTS = [(0, 0.5, 0.35, 0.049, 0.65, 0.4, 0), (0, 0.58, 0.48, 0.026, 0.8, 1.0, 1), (0, 0.7, -0.3, 0.038, 0.7, 1.2, 0),
         (0, 0.4, -0.45, 0.023, 0.8, 0.2, 1),
         (1, 0.55, -0.25, 0.043, 0.62, 0.0, 0), (1, 0.64, -0.42, 0.023, 0.9, 0.5, 1), (1, 0.38, 0.4, 0.029, 0.7, 2.2, 0),
         (2, 0.46, 0.25, 0.052, 0.6, 2.0, 0), (2, 0.68, -0.4, 0.032, 0.75, 0.3, 0), (2, 0.56, -0.12, 0.02, 0.9, 1.4, 1),
         (2, 0.33, -0.5, 0.025, 0.8, 0.8, 1),
         (3, 0.52, 0.32, 0.041, 0.66, 1.0, 0), (3, 0.62, 0.45, 0.022, 0.85, 2.4, 1), (3, 0.4, -0.38, 0.032, 0.7, 0.6, 0)]
# the nub's speckles: (heading, height, size)
NUB_SPOTS = [(-1.2, 0.17, 0.026), (2.6, 0.13, 0.02), (0.9, 0.2, 0.016)]


def _blob(r, ell, seed, n=9):
    """A slightly irregular little speckle outline."""
    return [(r * math.cos(a) * (1.0 + 0.18 * math.sin(3 * a + seed)), r * ell * math.sin(a) * (1.0 + 0.12 * math.cos(2 * a + seed)))
            for a in (k / n * math.tau for k in range(n))]


def _decor(P, gold):
    """The painted detail on the strips and the nub -> [(piece, rig tag)]."""
    out = []
    for k, spec in enumerate(PETALS):
        tagk = f"flap{k + 1}"

        def surf(t, a, spec=spec):
            return _surface(spec, t, a)
        for a in (-0.5, 0.5):        # two faint ridge lines down the strip (engraved on the golden one)
            out.append((DK.ribbon(surf, 0.14, 0.8, a, 0.045, P["ridge"], n=14, lift=0.003, name="ridge"), tagk))
        out.append((DK.ribbon(surf, 0.18, 0.6, -0.12, 0.13, P["gloss"], n=12, lift=0.004, name="gloss"), tagk))
        if gold:   # a gem near the tip and glitter
            g = DK.GEM_ORDER[k % 4]
            p, n = _surface(spec, 0.8, 0.0)
            out.append((DK.gem(P[g], p, n, 0.05, 0.04, facets=6, spin=0.3 * k, name="gem_" + g), tagk))
            for t, a, r in ((0.3, 0.3, 0.06), (0.62, -0.45, 0.05)):
                p, n = _surface(spec, t, a)
                out.append((DK.sparkle(P["sparkle"], p, n, r, spin=0.4 * k + t, lift=0.006), tagk))
    for k, t, a, r, ell, spin, light in SPOTS:
        p, n = _surface(PETALS[k], t, a)
        if gold:
            g = DK.GEM_ORDER[(k + int(t * 10)) % 5]
            pc = DK.gem(P[g], p, n, r * 0.95, r * 0.7, facets=5, spin=spin, name="gem_" + g) if not light else \
                DK.sparkle(P["glitter"], p, n, r * 1.3, spin=spin)
        else:
            pc = DK.flat_poly(P["spot"][light], _blob(r, ell, spin * 3.0), p, n, spin, lift=0.004, name="spot")
        out.append((pc, f"flap{k + 1}"))
    for a, z, r in NUB_SPOTS:
        p, n = _nub_point(a, z)
        if gold:
            pc = DK.sparkle(P["sparkle"], p, n, r * 1.4, spin=a)
        else:
            pc = DK.flat_poly(P["spot"][0], _blob(r, 0.75, a), p, n, a, lift=0.004, name="spot")
        out.append((pc, "Stem"))
    if gold:   # a ring of little gems round the stem's collar, one on each of the nub's ridges
        for i in range(5):
            a = (i * math.tau - 0.3) / 5
            p, n = _nub_point(a, 0.2)
            out.append((DK.gem(P[DK.GEM_ORDER[i]], p, n, 0.032, 0.026, facets=5, spin=a, name="gem"), "Stem"))
    return out


def build(gold=False):
    name = NAME + ("_Gold" if gold else "")
    P = _palette(gold)
    p = [DK.tag(_nub(P), "Stem")]
    p += DK.tag_all(_stem(P, gold), "Stem")
    hulls = []
    for k, spec in enumerate(PETALS):
        p.append(DK.tag(_petal(P, spec), f"flap{k + 1}"))
        hulls.append(DK.tag(_petal_hull(spec), f"flap{k + 1}"))
    for pc, t in _decor(P, gold):
        p.append(DK.tag(pc, t))
    body, outline = K.finish(p, name, outline_width=OUTLINE_W, outline_only=hulls)
    DK.no_bounce(outline)
    return [body, outline] + K.markers(name) + [items.grip(name, GRIP)]


BUILDERS = {NAME: build, NAME + "_Gold": lambda: build(True)}


# ---------------------------------------------------------------- skeleton
def _flap_bone(k):
    ang = math.radians(PETALS[k][0])
    d, _side = _dirs(ang)
    head = d * FLAP_IN + Vector((0, 0, THICK + ARCH + LIFT * 0.85))
    tail = d * PETALS[k][1] + Vector((0, 0, head.z))
    return head, tail


def _flap_field(k):
    d, _side = _dirs(math.radians(PETALS[k][0]))

    def f(p):
        r = Vector((p.x, p.y, 0.0)).dot(d)
        t = DK.smooth(FLAP_IN, FLAP_OUT, r)
        return DK.mix({"Stem": 1.0}, {f"Flap{k + 1}": 1.0}, t)
    return f


def rig(name, objs):
    """`<Name>_Rig`: Root + Stem + Flap1..Flap4 (see the module doc); skins the body and the outline."""
    stem_top = Vector(STEM_PATH[-1])
    bones = [DK.Bone("Root", None, (0, 0, 0), (0, -0.3, 0), deform=False),
             DK.Bone("Stem", "Root", (0, 0, 0.02), (0.0, 0.0, stem_top.z))]
    for k in range(4):
        head, tail = _flap_bone(k)
        bones.append(DK.Bone(f"Flap{k + 1}", "Root", head, tail, z=(0, 0, 1)))
    fields = {f"flap{k + 1}": _flap_field(k) for k in range(4)}
    return DK.skin(name, objs, bones, fields)


# test poses for preview.py --pose (rigging.apply_pose; ("local", 1, 0, 0) = the Flap's own X: + lifts)
LIFT_X = ("local", 1, 0, 0)
POSES = {
    "rest": {},
    "flop": {"Flap1": [(LIFT_X, 55)], "Flap2": [(LIFT_X, 35)], "Flap3": [(LIFT_X, 60)], "Flap4": [(LIFT_X, 40)]},
    "slip": {"Stem": [((1, 0, 0), 14)], "Flap1": [(LIFT_X, 80)], "Flap2": [(LIFT_X, -8)], "Flap3": [(LIFT_X, 25)],
             "Flap4": [(LIFT_X, 70)]},
    "quiver": {"Stem": [((0, 1, 0), -10)], "Flap1": [(LIFT_X, 12)], "Flap2": [(LIFT_X, -6)], "Flap3": [(LIFT_X, 10)],
               "Flap4": [(LIFT_X, -6)]},
    "twist": {"Stem": [((0, 0, 1), 35)], "Flap1": [(("local", 0, 0, 1), 20)], "Flap3": [(("local", 0, 0, 1), -20)]},
}
