"""
items/towel.py - the Towel Snap's towels (ReplicatedStorage.ItemMeshes.Towel_<Look>): a flat bath
towel held bunched at the middle of one short end. One shape, seven looks (ItemConfig.TowelLooks by
Towel Snap level, plus the Royal Towel pass), see LOOKS. See items/__init__.py for the conventions
every item follows, with ONE exception: the towels have no `_Outline` hull. Roblox's automatic
moderation removed the old rolled towel's outline mesh (a bare silhouette, seen on its own, can be
misread), so the game draws the towel's cartoon outline with a Highlight and the ink edge is painted
on the cloth instead. Every GLB holds just the body, its skeleton and the markers.

The shape (grip at the origin, the towel pointing -Y, its flat side up; Blender studs):
- the cloth: one thin closed slab (THICK, its long hems a little thicker), a rectangle 2 * HALF_W
  wide and LENGTH long, flat side up. Its near edge (Y_NEAR, just behind the grip) is held bunched
  in the fist at its middle: pinched a little narrower (PINCH, easing out by L_FAN), its corners
  hanging a touch lower (TENT), deeper pleats there, held flat up to L_GATHER. Soft folds run along
  it (waves across the width, calmer under the emblem), it ripples gently along its length like a
  flag and sags a little toward the far end; seen edge-on it is an even, thin wavy strip from the
  hand to the fringe. Nothing on it is round: no roll, no knob, no ball, no tassel, no taper;
- the far end: a straight, square-cornered hem with a flat fringe (FRINGE_N short flat strips with
  square ends);
- per look: colours, hem stripes and bands ACROSS it and stripes along it (cut along clean iso-lines
  of the cloth coordinates, wavy for the Beach's sea), an ink line painted along every edge (the
  slab's rim plus a thin border on both faces) and a printed emblem lying flat on both faces (star,
  sun, flower, crown: one flat multi-colour layer, upright when the towel hangs from the hand,
  fringe down; underneath it is mirrored so it reads the same from below). Folds facing the cartoon
  key light (KEY) take a colour's light tone; the bake paints the rest (fuzzy "felt" for terry
  cloth, soft "fluff" for the Spa, which is also thicker with puffier hems).
Each look is ~2.7k-3.7k triangles in ONE mesh (the old roll + its hull were 4.5k-6k).

The skeleton (`rig`, the same for every look): `Root` at the grip (unweighted), `Seg1` = the part
bunched in the fist (grip to just ahead of the fist, weighted 100% back to y = -0.3: rigid), then
`Seg2`...`Seg6` along the cloth to the end of the fringe. Every bone points along -Y with no rest
rotation beyond that (head -> tail = local +Y toward the far end, local +Z = up, local +X = model -X),
so turning a Seg about model +X curls everything past it down (across the cloth's thin side, the way
cloth bends), about -X up. The whole body (cloth, fringe, emblems) is weighted by one smooth field
along the length: two bones blended over a band round each joint, the bands touching, so the cloth
bends as a continuous curve. Tested (one joint at a time, Plain): bending across the cloth (about X)
is clean to 120 degrees at Seg3..Seg6 and 90 at Seg2 (just ahead of the fist); bending in the cloth's
own plane (about Z) only to ~20 degrees (30 shows an elbow, 45 creases the inside edge: a 1.5 wide
sheet can't bend sideways), so on ItemRig's swing axis (1, 0.3, 0), whose sideways part is 0.29 of
the turn, ~70 degrees per joint; a 20 degree twist per joint is clean. `POSES` holds preview.py's
test poses.
"""
import math

import bmesh
from mathutils import Vector
from mathutils.geometry import delaunay_2d_cdt

import items
import rigging
import sockkit as K
from sockkit import hexcol

# ---------------------------------------------------------------- layout (studs; grip at the origin, far end at -Y)
HALF_W = 0.75           # half the towel's width (1.5 across)
LENGTH = 4.0            # cloth length from the near edge (behind the fist) to the far hem
Y_NEAR = 0.24           # the near edge
THICK = 0.1             # cloth thickness (a soft hem a little thicker, HEM_PUFF)
HEM_PUFF = 0.18
PINCH = 0.1             # the near edge is pinched this much narrower (share of the width) ...
TENT = 0.06             # ... and its corners hang this far below the fist
L_GATHER = 0.3          # held flat in the fist up to here (cloth length from the near edge) ...
L_FAN = 1.1             # ... the pinch has fanned out to the full width by here
FOLD_K = 2.5            # half waves of the soft folds across the width
FOLD_A = 0.042          # their height on the free cloth ...
PLEAT_A = 0.05          # ... and where it is bunched ...
CALM = 0.35             # ... and this share lower under the emblem (so the print lies calm)
WAVE_A = 0.07           # the gentle ripple along the length ...
WAVE_L = 2.3            # ... its wavelength
SAG = 0.1               # the far end sags this much
EDGE_A = 0.018          # the long edges flutter a little
FRINGE_N = 13           # flat fringe strips across the far end (odd: one on the centre line)
FRINGE_L = 0.17         # their length past the hem
FRINGE_W = 0.068        # their width
INK_U = 0.034           # the painted ink line along the long edges (share of the half width) ...
INK_L = 0.026           # ... and across the ends (studs)
STEP_L = 0.15           # grid rows along the towel (at most this far apart)
N_U = 12                # grid columns across (at least)
KEY = Vector((-0.42, -0.3, 0.86)).normalized()   # cartoon key light: folds facing it take the light tone
TONE_CUT = 0.8
L_TIP = LENGTH + FRINGE_L                         # the end of the fringe (cloth length)
Y_TIP = Y_NEAR - L_TIP
L_EMBLEM = 2.25         # the printed emblem's centre (cloth length), one flat layer ...
PRINT_LIFT = 0.016      # ... lying this far off the cloth (just clear of the cloth's facets)

# the skeleton: bone heads (y) of Seg1..Seg6 (the last tail is the end of the fringe); blend half
# widths at each joint (Seg1's blend starts at y = -0.3: everything in the fist rides it alone)
JOINTS = [0.0, -0.5, -1.3, -2.04, -2.72, -3.34]
BLEND = [None, 0.2, 0.38, 0.35, 0.32, 0.29]

TOP, BOTTOM, RIM = 1, -1, 0


def _smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


# ---------------------------------------------------------------- the cloth's surface
def _near(L):
    """1 at the pinched near edge, easing to 0 where the cloth has fanned out to its full width."""
    return 1.0 - _smooth(0.0, L_FAN, L)


def half_width(L):
    """Half width of the cloth at cloth length L (pinched at the near edge, full width ahead of it)."""
    return HALF_W * (1.0 - PINCH * _near(L))


def _height(u, L):
    """Height of the cloth's middle surface at (u across -1..1, L along): folds, the pinch's
    hanging corners, ripple, sag, flutter."""
    free = _smooth(L_GATHER, L_FAN + 0.4, L)              # 0 in the fist (held flat), 1 on the free cloth
    amp = PLEAT_A + (FOLD_A - PLEAT_A) * _smooth(L_GATHER, L_FAN + 0.5, L)
    amp *= 1.0 - CALM * (1.0 - _smooth(0.3, 0.75, abs(u))) * (1.0 - _smooth(0.45, 0.95, abs(L - L_EMBLEM)))
    z = amp * math.sin(math.pi * FOLD_K * u + 0.6 + 0.5 * math.sin(0.9 * L))
    z -= TENT * u * u * _near(L)
    t = max(0.0, L - L_GATHER) / (LENGTH - L_GATHER)
    z += free * WAVE_A * math.sin(2 * math.pi * (L - 1.0) / WAVE_L) - SAG * t * t
    z += free * EDGE_A * u ** 4 * math.sin(2 * math.pi * L / 1.7 + (1.0 if u > 0 else 3.2))
    return z


def _mid(u, L):
    """The cloth's middle surface (its faces are THICK / 2 straight above and below it)."""
    return Vector((u * half_width(L), Y_NEAR - L, _height(u, L)))


def _normal(u, L):
    e = 1e-3
    du = _mid(u + e, L) - _mid(u - e, L)
    dl = _mid(u, L + e) - _mid(u, L - e)
    return dl.cross(du).normalized()       # (-Y) x (+X) = +Z: the top side


def _half_t(u, thick, puff):
    """Half thickness (the faces are offset straight up / down: no fold ever pinches through); the
    long hems are `puff` thicker."""
    return thick * 0.5 * (1.0 + puff * _smooth(0.8, 1.0, abs(u)))


# ---------------------------------------------------------------- looks
def _tones(look, part, base, light):
    """(light, base) palette indices; the shaded side comes from the bake's own shading."""
    return hexcol(f"towel_{look}_{part}_light", light), hexcol(f"towel_{look}_{part}", base)


def _palette(look):
    """-> {family: (light, base) palette indices, or a single index} for one look."""
    L = look.lower()
    P = {}
    if look == "Plain":
        P["body"] = _tones(L, "body", "#8CCBF5", "#B4E0FF")
        P["hem"] = _tones(L, "hem", "#F6FAFD", "#FFFFFF")
    elif look == "Striped":
        P["body"] = _tones(L, "body", "#F7F5EF", "#FFFFFF")
        P["blue"] = _tones(L, "blue", "#3D7DE0", "#6CA2F2")
        P["red"] = _tones(L, "red", "#E8453C", "#FF7468")
    elif look == "Beach":
        P["body"] = _tones(L, "body", "#FFCB2E", "#FFE36E")
        P["orange"] = _tones(L, "orange", "#FF8A2A", "#FFAA5C")
        P["teal"] = _tones(L, "teal", "#1FB3AE", "#52D6CF")
        P["foam"] = _tones(L, "foam", "#F4FBFA", "#FFFFFF")
        P["sun"] = hexcol("towel_beach_sun", "#FFE680")
        P["ray"] = hexcol("towel_beach_ray", "#FF6A1F")
    elif look == "Spa":
        P["body"] = _tones(L, "body", "#F3E8EC", "#FFFFFF")
        P["hem"] = _tones(L, "hem", "#F7A8C8", "#FFC6DD")
        P["petal"] = hexcol("towel_spa_petal", "#FF86B8")
        P["centre"] = hexcol("towel_spa_centre", "#FFD24D")
        P["leaf"] = hexcol("towel_spa_leaf", "#7FD49A")
    elif look == "Sports":
        P["body"] = _tones(L, "body", "#22A447", "#4CC66A")
        P["hem"] = _tones(L, "hem", "#F6F8F4", "#FFFFFF")
        P["star"] = hexcol("towel_sports_star", "#FFFFFF")
    elif look == "Champion":
        P["body"] = _tones(L, "body", "#B5182E", "#DA3349")
        P["hem"] = _tones(L, "hem", "#F4C23A", "#FFE07A")
        P["star"] = hexcol("towel_champion_star", "#FFD447")
        P["star_light"] = hexcol("towel_champion_star_light", "#FFF0A0")
    elif look == "Royal":
        P["body"] = _tones(L, "body", "#6C3BB4", "#8E5FD8")
        P["hem"] = _tones(L, "hem", "#F4C23A", "#FFE07A")
        P["crown"] = hexcol("towel_royal_crown", "#FFCF3F")
        P["crown_light"] = hexcol("towel_royal_crown_light", "#FFEC94")
        P["stitch"] = hexcol("towel_royal_stitch", "#9A5A10")
        P["gem"] = hexcol("towel_royal_gem", "#E8334E")
    P["ink"] = hexcol(f"towel_{L}_ink", "#2A1838")
    return P


def _hems(fam, near=((0.64, 0.72), (0.78, 0.83)), far=((0.36, 0.44), (0.25, 0.3))):
    """Hem stripes across the towel near both ends (near: from the near edge; far: from the far hem)."""
    return [(a, b, fam) for a, b in near] + [(LENGTH - b, LENGTH - a, fam) for a, b in far]


def _candy():
    out = []
    for k in range(6):
        s = 0.62 + 0.53 * k
        out += [(s, s + 0.15, "blue"), (s + 0.24, s + 0.32, "red")]
    return out


# per look:
#   bands   (from, to, family[, "w"]) across the towel, by cloth length (or by the wavy field "w");
#           the last match wins; bands win over cols
#   cols    (from, to, family): stripes along the towel, by |u| (0 = the centre line, 1 = the edge)
#   wave    (amplitude, half waves across, phase) of the "w" field: w = L + amplitude * sin(...)
#   fringe  family of the fringe strips; emblem: the printed badge; thick: cloth thickness, puff: hem
LOOKS = {
    "Plain": dict(bands=_hems("hem"), cols=[], fringe="body"),
    "Striped": dict(bands=_candy(), cols=[], fringe="red"),
    "Beach": dict(bands=[(0.62, 0.78, "orange"), (2.96, 9.0, "teal", "w"), (2.96, 3.03, "foam", "w"),
                         (3.33, 3.38, "foam", "w")],
                  cols=[], wave=(0.075, 4.0, 0.5), fringe="teal", emblem="sun"),
    "Spa": dict(bands=[(0.6, 0.8, "hem"), (LENGTH - 0.42, LENGTH, "hem")], cols=[(0.86, 1.0, "hem")],
                fringe="hem", emblem="flower", thick=0.13, puff=0.35),
    "Sports": dict(bands=[(0.62, 0.78, "hem"), (LENGTH - 0.46, LENGTH - 0.3, "hem")], cols=[(0.66, 0.74, "hem")],
                   fringe="hem", emblem="bigstar"),
    "Champion": dict(bands=_hems("hem", far=((0.38, 0.46), (0.26, 0.3))), cols=[(0.85, 0.91, "hem")],
                     fringe="hem", emblem="goldstar"),
    "Royal": dict(bands=[(0.6, 0.8, "hem"), (LENGTH - 0.52, LENGTH - 0.3, "hem"),
                         (LENGTH - 0.22, LENGTH - 0.17, "hem")],
                  cols=[(0.84, 0.91, "hem")], fringe="hem", emblem="crown"),
}


# ---------------------------------------------------------------- mesh helpers
def _iso_cut(bm, F, key, cuts, same_side=False):
    """Splits the faces of `bm` along the iso-lines F[key] == c for every c in `cuts`, so a colour
    step drawn at c is a clean line instead of a stair of whole faces. F: {field: {vert: value}};
    every field is interpolated onto the new verts. same_side: never split an edge between the top
    and the bottom face (the tone field flips sign there). The surface itself is unchanged."""
    vals = F[key]
    for c in cuts:
        for v in bm.verts:
            if abs(vals[v] - c) < 1e-6:
                vals[v] = c + 1e-6
        new = set()
        for e in list(bm.edges):
            a, b = e.verts
            if same_side and F["s"][a] != F["s"][b]:
                continue
            va, vb = vals[a], vals[b]
            if (va - c) * (vb - c) < 0:
                t = (c - va) / (vb - va)
                _, nv = bmesh.utils.edge_split(e, a, t)
                for d in F.values():
                    d[nv] = d[a] + (d[b] - d[a]) * t
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


def _slab(us, Ls, thick, puff=HEM_PUFF):
    """A closed thin slab over the cloth surface: top and bottom grids over us x Ls joined by a rim.
    -> (bmesh with an int face layer "side" (TOP / BOTTOM / RIM), fields {u, L, s, t: {vert: value}})."""
    bm = bmesh.new()
    side = bm.faces.layers.int.new("side")
    F = {"u": {}, "L": {}, "s": {}, "t": {}}
    top, bot = {}, {}
    for i, u in enumerate(us):
        for j, L in enumerate(Ls):
            m, n = _mid(u, L), _normal(u, L)
            h = _half_t(u, thick, puff)
            for grid, s in ((top, 1.0), (bot, -1.0)):
                v = bm.verts.new(m + Vector((0.0, 0.0, s * h)))
                grid[i, j] = v
                F["u"][v], F["L"][v], F["s"][v], F["t"][v] = u, L, s, s * n.dot(KEY)
    ni, nj = len(us) - 1, len(Ls) - 1
    for i in range(ni):
        for j in range(nj):
            f = bm.faces.new((top[i, j], top[i, j + 1], top[i + 1, j + 1], top[i + 1, j]))
            f[side] = TOP
            g = bm.faces.new((bot[i, j], bot[i + 1, j], bot[i + 1, j + 1], bot[i, j + 1]))
            g[side] = BOTTOM
    ring = [(i, 0) for i in range(ni)] + [(ni, j) for j in range(nj)] + [(i, nj) for i in range(ni, 0, -1)] \
        + [(0, j) for j in range(nj, 0, -1)]
    for k in range(len(ring)):
        a, b = ring[k], ring[(k + 1) % len(ring)]
        f = bm.faces.new((top[a], top[b], bot[b], bot[a]))
        f[side] = RIM
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()
    if sum(f.normal.z for f in bm.faces if f[side] == TOP) < 0:   # inside out: turn it round
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    return bm, F


def _tone(tones, t, side):
    if isinstance(tones, int):
        return tones
    return tones[0] if side == TOP and t > TONE_CUT else tones[1]


def _piece(bm, pals, flat, name):
    p = K.Piece(K._bm_to_mesh(bm, name), pals, False, True, name)
    p.flat_faces = flat
    return p


# ---------------------------------------------------------------- the cloth
def _family(spec, u, L, w):
    if abs(u) > 1.0 - INK_U or L < INK_L or L > LENGTH - INK_L:
        return "ink"
    fam = "body"
    for a, b, fm in spec["cols"]:
        if a <= abs(u) < b:
            fam = fm
    for band in spec["bands"]:
        a, b, fm = band[:3]
        val = w if band[3:] == ("w",) else L
        if a <= val < b:
            fam = fm
    return fam


def _wave_of(spec, u):
    amp, k, ph = spec.get("wave", (0.0, 0.0, 0.0))
    return amp * math.sin(math.pi * k * u + ph) if amp else 0.0


def _fill(points, step):
    """Sorted grid positions: every one of `points`, with even steps no longer than `step` between."""
    pts = sorted(points)
    out = [pts[0]]
    for a, b in zip(pts, pts[1:]):
        n = max(1, int(math.ceil((b - a) / step - 1e-6)))
        out += [a + (b - a) * k / n for k in range(1, n + 1)]
    return out


def _cloth(P, spec):
    thick, puff = spec.get("thick", THICK), spec.get("puff", HEM_PUFF)
    # straight colour steps lie on grid lines (no extra cuts); the wavy ones and the tone are cut
    ucuts = {-1.0, 1.0, 1.0 - INK_U, INK_U - 1.0}
    for a, b, _fm in spec["cols"]:
        ucuts |= {x * s for x in (a, b) if 0.0 < x < 1.0 - INK_U for s in (1.0, -1.0)}
    lcuts, wcuts = {0.0, LENGTH, INK_L, LENGTH - INK_L}, set()
    for band in spec["bands"]:
        for x in band[:2]:
            if INK_L < x < LENGTH - INK_L:
                (wcuts if band[3:] == ("w",) else lcuts).add(x)
    bm, F = _slab(_fill(ucuts, 2.0 / N_U), _fill(lcuts, STEP_L), thick, puff)
    F["w"] = {v: F["L"][v] + _wave_of(spec, F["u"][v]) for v in bm.verts}
    _iso_cut(bm, F, "w", sorted(wcuts))
    _iso_cut(bm, F, "t", (TONE_CUT,), same_side=True)
    side = bm.faces.layers.int["side"]
    pals, flat = [], []
    for i, f in enumerate(bm.faces):
        vs = f.verts
        if f[side] == RIM:
            pals.append(P["ink"])
            flat.append(i)
            continue
        u, L, w, t = (sum(F[k][v] for v in vs) / len(vs) for k in ("u", "L", "w", "t"))
        pals.append(_tone(P[_family(spec, u, L, w)], t, f[side]))
    return _piece(bm, pals, flat, "cloth")


def _fringe(P, spec):
    """Flat strips with square ends past the far hem (they start a little inside the cloth)."""
    thick = spec.get("thick", THICK) * 0.6
    tones = P[spec["fringe"]]
    out = []
    du = FRINGE_W * 0.5 / HALF_W
    for i in range(FRINGE_N):
        uc = -1.0 + (2 * i + 1) / FRINGE_N
        end = LENGTH + FRINGE_L * (1.0 - 0.12 * (0.5 + 0.5 * math.sin(i * 2.4 + 0.7)) if i != FRINGE_N // 2 else 1.0)
        bm, F = _slab([uc - du, uc + du], [LENGTH - 0.03, (LENGTH + end) * 0.5, end], thick, 0.0)
        side = bm.faces.layers.int["side"]
        pals, flat = [], []
        for k, f in enumerate(bm.faces):
            if f[side] == RIM:
                pals.append(P["ink"])
                flat.append(k)
            else:
                t = sum(F["t"][v] for v in f.verts) / len(f.verts)
                pals.append(_tone(tones, t, f[side]))
        out.append(_piece(bm, pals, flat, "fringe"))
    return out


# ---------------------------------------------------------------- printed emblems (flat on both faces)
def _densify(poly, step):
    out = []
    n = len(poly)
    for i in range(n):
        a, b = Vector(poly[i]), Vector(poly[(i + 1) % n])
        k = max(1, int(math.ceil((b - a).length / step)))
        out += [a.lerp(b, j / k) for j in range(k)]
    return out


def _inside(poly, q):
    c = False
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        if (a[1] > q[1]) != (b[1] > q[1]):
            if q[0] < a[0] + (q[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1]):
                c = not c
    return c


def _seg_dist(q, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (q - a).dot(ab) / max(ab.length_squared, 1e-12)))
    return (q - (a + ab * t)).length


def _grow(pts, d):
    """Polygon pushed out by ~d from its centroid (the ink border under a print)."""
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    out = []
    for x, y in pts:
        l = math.hypot(x - cx, y - cy)
        k = (l + d) / max(l, 1e-6)
        out.append((cx + (x - cx) * k, cy + (y - cy) * k))
    return out


def _star2d(r_out, r_in, n=5):
    return [((r_out if i % 2 == 0 else r_in) * math.cos(math.pi / 2 + math.pi * i / n),
             (r_out if i % 2 == 0 else r_in) * math.sin(math.pi / 2 + math.pi * i / n)) for i in range(2 * n)]


def _circle2d(cx, cy, r, n=14, sx=1.0, rot=0.0):
    out = []
    for i in range(n):
        a = 2 * math.pi * i / n
        x, y = r * sx * math.cos(a), r * math.sin(a)
        out.append((cx + x * math.cos(rot) - y * math.sin(rot), cy + x * math.sin(rot) + y * math.cos(rot)))
    return out


def _print(regions, thick, puff, step=0.085, inner=0.136):
    """The emblem as ONE flat layer: `regions` = [(polygon, palette index)] in paint order (a later
    region covers an earlier one), in emblem coordinates (x = right, y = up = toward the hand, as
    seen from above with the hand end up: upright when the towel hangs from the hand, and in the
    item icon, which shows the fringe at the bottom). They are triangulated together (every colour step an exact
    edge, nothing stacked, so nothing can show through) with interior points so the print follows the
    cloth's folds, then laid PRINT_LIFT off both faces of the cloth round (0, L_EMBLEM); underneath
    it is mirrored, so it reads the same from below."""
    rings = [_densify(poly, step) for poly, _pal in regions]
    pts, faces, edges = [], [], []
    for ring in rings:
        faces.append(list(range(len(pts), len(pts) + len(ring))))
        edges += [(ring[i], ring[(i + 1) % len(ring)]) for i in range(len(ring))]
        pts += [Vector((p.x, p.y)) for p in ring]
    xs, ys = [p.x for p in pts], [p.y for p in pts]
    x = min(xs) + inner * 0.5
    while x < max(xs):
        y = min(ys) + inner * 0.5
        while y < max(ys):
            q = Vector((x, y))
            if any(_inside(poly, q) for poly, _pal in regions) \
                    and min(_seg_dist(q, a, b) for a, b in edges) > inner * 0.45:
                pts.append(q)
            y += inner
        x += inner
    verts2d, _edges, tris, _ov, _oe, orig = delaunay_2d_cdt(pts, [], faces, 1, 1e-7, True)
    out = []
    for s in (1.0, -1.0):
        bm = bmesh.new()
        vs = []
        for q in verts2d:
            L = L_EMBLEM - q.y
            u = (q.x * s) / half_width(L)        # seen from above with the hand end up, right = +X
            p = _mid(u, L) + Vector((0.0, 0.0, s * _half_t(u, thick, puff))) + _normal(u, L) * (s * PRINT_LIFT)
            vs.append(bm.verts.new(p))
        pals = []
        for f, o in zip(tris, orig):
            if not o:
                continue
            try:
                bm.faces.new([vs[i] for i in f])
            except ValueError:
                continue
            pals.append(regions[max(o)][1])
        bm.normal_update()
        for f in bm.faces:
            if f.normal.z * s < 0:
                f.normal_flip()
        out.append(K.Piece(K._bm_to_mesh(bm, "print"), pals, False, True, "print"))
    return out


def _emblem(kind, P):
    """The look's printed badge as regions for _print (and its edge step): an ink border with the
    coloured design on it."""
    ink = P["ink"]
    R = []
    if kind in ("bigstar", "goldstar"):
        r = 0.5 if kind == "bigstar" else 0.43
        star = _star2d(r, r * 0.46)
        R += [(_grow(star, 0.045), ink), (star, P["star"])]
        if "star_light" in P:          # a lighter inner star (the gold's sheen)
            R.append(([(x * 0.5, y * 0.5 + 0.015) for x, y in star], P["star_light"]))
    elif kind == "sun":
        rays = []
        for i in range(10):
            a = 2 * math.pi * i / 10 + math.pi / 2
            a1, a2 = a - 0.19, a + 0.19
            rays += [(0.23 * math.cos(a1), 0.23 * math.sin(a1)), (0.4 * math.cos(a), 0.4 * math.sin(a)),
                     (0.23 * math.cos(a2), 0.23 * math.sin(a2))]
        disc = _circle2d(0.0, 0.0, 0.24, 16)
        R += [(_grow(rays, 0.04), ink), (rays, P["ray"]), (_grow(disc, 0.035), ink), (disc, P["sun"])]
    elif kind == "flower":
        for a in (-2.25, -0.89):
            leaf = _circle2d(0.33 * math.cos(a), 0.33 * math.sin(a), 0.11, 10, sx=1.8, rot=a)
            R += [(_grow(leaf, 0.03), ink), (leaf, P["leaf"])]
        flower = []                     # five round petals in one outline
        for k in range(40):
            a = 2 * math.pi * k / 40 + math.pi / 2
            r = 0.3 * (0.62 + 0.38 * abs(math.cos(2.5 * (a - math.pi / 2))) ** 0.8)
            flower.append((r * math.cos(a), r * math.sin(a)))
        R += [(_grow(flower, 0.035), ink), (flower, P["petal"])]
        c = _circle2d(0.0, 0.0, 0.09, 10)
        R += [(_grow(c, 0.025), ink), (c, P["centre"])]
    elif kind == "crown":
        w = 0.34
        crown = [(-w, -0.2), (w, -0.2), (w * 1.18, 0.26), (w * 0.5, 0.05), (0.0, 0.3), (-w * 0.5, 0.05),
                 (-w * 1.18, 0.26)]
        R += [(_grow(crown, 0.045), ink), (crown, P["crown"])]
        R.append(([(-w * 0.94, -0.17), (w * 0.94, -0.17), (w * 0.94, -0.08), (-w * 0.94, -0.08)], P["crown_light"]))
        for gx in (-0.19, 0.0, 0.19):           # flat diamond gems on the band
            R.append(([(gx, -0.165), (gx + 0.045, -0.125), (gx, -0.085), (gx - 0.045, -0.125)], P["gem"]))
        # the stitching: little dashes just inside the crown's edge (above the band)
        edge = _grow(crown, -0.04)
        for i in range(len(edge)):
            x0, y0 = edge[i]
            x1, y1 = edge[(i + 1) % len(edge)]
            L = math.hypot(x1 - x0, y1 - y0)
            nd = max(1, int(L / 0.09))
            for q in range(nd):
                t0, t1 = (q + 0.2) / nd, (q + 0.7) / nd
                ax, ay = x0 + (x1 - x0) * t0, y0 + (y1 - y0) * t0
                bx, by = x0 + (x1 - x0) * t1, y0 + (y1 - y0) * t1
                nx, ny = -(y1 - y0) / L * 0.009, (x1 - x0) / L * 0.009
                dash = [(ax - nx, ay - ny), (bx - nx, by - ny), (bx + nx, by + ny), (ax + nx, ay + ny)]
                R.append((dash, P["stitch"]))
    return R, (0.2 if kind == "sun" else 0.085)    # the sun's short rays need no extra edge points


# ---------------------------------------------------------------- build
def build_towel(look):
    name = "Towel_" + look
    P = _palette(look)
    spec = LOOKS[look]
    pieces = [_cloth(P, spec)] + _fringe(P, spec)
    if spec.get("emblem"):
        regions, step = _emblem(spec["emblem"], P)
        pieces += _print(regions, spec.get("thick", THICK), spec.get("puff", HEM_PUFF), step)
    body = K.textured_object(pieces, name)       # the body only: NO outline hull (see the top)
    tip = _mid(0.0, L_TIP)
    return [body] + K.markers(name) + [items.grip(name, (0.0, 0.0, 0.0)), K.marker(name + "_Tip", tip)]


BUILDERS = {"Towel_" + look: (lambda look=look: build_towel(look)) for look in LOOKS}

# texture classes for tools/blender/texturing.py: the towels are soft terry cloth (fuzzy felt), the
# Spa extra fluffy; the prints are part of the cloth
MATERIALS = {"towel": "felt", "towel_spa": "fluff"}


# ---------------------------------------------------------------- skeleton
def _field(y):
    """Seg weights along the towel at height y (toward the far end = smaller y)."""
    w = {"Seg1": 1.0}
    for k in range(1, 6):
        J, h = JOINTS[k], BLEND[k]
        if y <= J + h:
            t = _smooth(0.0, 1.0, (J + h - y) / (2 * h))
            w = {f"Seg{k}": 1.0 - t, f"Seg{k + 1}": t}
    return {b: v for b, v in w.items() if v > 0.0}


def rig(name, objs):
    """`<Name>_Rig`: Root at the grip + Seg1..Seg6 to the end of the fringe; skins the body (the only
    mesh: the towels have no outline hull)."""
    body = objs[0]
    W = [rigging._finalise(_field(v.co.y)) for v in body.data.vertices]
    bones = {"Root": rigging.Bone("Root", None, (0, 0, 0), (0, -0.3, 0), "root")}
    heads = JOINTS + [Y_TIP]
    for k in range(6):
        bones[f"Seg{k + 1}"] = rigging.Bone(f"Seg{k + 1}", "Root" if k == 0 else f"Seg{k}", (0, heads[k], 0),
                                            (0, heads[k + 1], 0), "seg", index=k + 1)
    ao = rigging.build_armature(name + "_Rig", bones)
    ao.matrix_world = body.matrix_world.copy()      # preview.py moves items apart before rigging
    rigging._skin(body, ao, W)
    return ao


# test poses for preview.py --pose (rigging.apply_pose: world axes; +X turns the towel down).
# GAME = ItemRig's swing axis (Vector3.new(1, 0.3, 0) in the handle's space) in Blender axes.
GAME = (1.0, 0.0, 0.3)
POSES = {
    "rest": {},
    "windup": {"Seg1": [((1, 0, 0), -17)], "Seg2": [((1, 0, 0), -35)], "Seg3": [((1, 0, 0), -35)],
               "Seg4": [((1, 0, 0), -35)], "Seg5": [((1, 0, 0), -40)], "Seg6": [((1, 0, 0), -40)]},
    # the lash at the game's own limits, about its own axis (a little sideways in the cloth's plane)
    "crack": {"Seg2": [(GAME, 45)], "Seg3": [(GAME, 45)], "Seg4": [(GAME, -45)],
              "Seg5": [(GAME, -72)], "Seg6": [(GAME, 72)]},
    "droop": {"Seg2": [((1, 0, 0), 35)], "Seg3": [((1, 0, 0), 30)], "Seg4": [((1, 0, 0), 18)],
              "Seg5": [((1, 0, 0), 10)], "Seg6": [((1, 0, 0), 6)]},
    # rolled down across the cloth: 60 degrees at every flexible joint (300 degrees, just short of
    # touching itself; every joint takes 90+ cleanly on its own)
    "curl": {f"Seg{k}": [((1, 0, 0), 60)] for k in range(2, 7)},
}
