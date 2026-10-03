"""
items/towel.py - the Towel Snap's towels (ReplicatedStorage.ItemMeshes.Towel_<Look>): a bath towel
rolled up and twisted into a locker-room whip, held at its fat folded end. One shape, seven looks
(ItemConfig.TowelLooks by Towel Snap level, plus the Royal Towel pass), see LOOKS.
See items/__init__.py for the conventions every item follows.

The shape (grip at the origin, the towel pointing -Y; 4.6 studs from the fold to the tip, the
Spa's pom-pom and the Royal's tassel hang on past it):
- the roll: one tube twisted into two fat strands (LOBES) that holds its thickness, then tapers into
  a thin "rat-tail" ending in a little bulb (the towel's corner). Its vertex columns follow the
  twist, so helical stripes (the terry hem beside the groove, candy stripes) are whole face columns;
  rings across it (the towel's border stripes) are cut along clean iso-lines (wavy for the Beach);
- the handle: the roll's thick end with the towel's end folded back over its top (the flap), round
  the back of the fist in a U and tucked under; its free end, pressed on the roll ahead of the fist,
  shows the border stripes; ~0.73 thick;
- per look: colours, stripes, a sewn-on badge on top of the roll just ahead of the fist (star, sun,
  flower, crown; its top points to the tip) and the Spa's pom-pom / the Royal's gold tassel.
The light top tone is cut along an iso-line of the surface normal like the props; the bake paints
the rest (soft "felt" fuzz for terry, "fluff" for the Spa). The roll gets its own outline hull (same
mesh, ink thinning toward the tip), and the hull is smooth-shaded (see build_towel).

The skeleton (`rig`, the same for every look): `Root` at the grip (unweighted), `Seg1` = the handle
(grip to the joint just ahead of the flap: the flap rides it whole), `Seg2`...`Seg6` along the roll to
the towel's tip. Every bone points along -Y with no rest rotation (head -> tail = local +Y toward the
tip, local +Z = up, local +X = model -X), so turning a Seg about model +X curls everything past it
down, about -X up, about Z sideways. The roll is weighted smoothly by length (two bones blended over
a band round each joint, the bands touching), badges ride the bone under their centre, the pom-pom
and the tassel ride Seg6; the outline hull gets the same weights from the same field. Tested clean:
45 degrees at every flexible joint at once (a 225 degree curl), sideways too; 60 bunches the thick
joints' inner side like cloth (no tears); a 30 degree twist per joint about its own Y. `POSES` holds
preview.py's test poses.
"""
import math

import bmesh
from mathutils import Vector

import items
import rigging
import sockkit as K
from sockkit import hexcol

# ---------------------------------------------------------------- layout (studs; grip at the origin, tip at -Y)
OUT_W = 0.045           # ink width at the handle (flap, badge, tassel)
TIP_W = 0.026           # ... the roll's own hull thins to this at the tip
N_AROUND = 12           # vertex columns round the roll
LOBES = 2               # twisted strands
PER = N_AROUND // LOBES  # face columns per strand (helical stripes are whole columns)
RING_STEP = 0.09        # ring spacing along the roll
Y_BACK = 0.3            # centre of the roll's rounded back end (under the fold)
Y_FLAP = -0.64          # the flap's free end
S_TIP = 3.86            # the very tip of the towel (s = -y)
R_TIP = 0.078           # the soft corner bulb at the tip
# roll radius stations (s = -y, radius at the strands' crest): a rope that holds its thickness,
# then tapers into a thin rat-tail ending in a little bulb (the towel's corner)
RADII = [(-0.4, 0.27), (0.0, 0.27), (0.45, 0.28), (0.8, 0.31), (1.2, 0.32), (1.75, 0.305), (2.25, 0.26),
         (2.7, 0.19), (3.05, 0.125), (3.35, 0.085), (3.55, 0.066), (3.68, 0.07), (S_TIP - R_TIP, R_TIP)]
TWIST = 1.9             # twist rate: d(angle)/ds = TWIST / (R + TWIST_R0)
TWIST_R0 = 0.2
GROOVE = 0.27           # groove depth (share of the radius)
LUMP = 0.045            # soft lumps along the roll (share of the radius)
TONE_CUT = 0.52         # normal z above which a colour takes its light tone

# the skeleton: bone heads (y) of Seg1..Seg6 (the last tail is the tip); blend half widths at each joint
JOINTS = [0.0, -0.86, -1.6, -2.26, -2.84, -3.36]
BLEND = [None, 0.2, 0.33, 0.29, 0.26, 0.25]


def _smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def _interp(s, rows):
    """Catmull-Rom through rows[i] = (s, value)."""
    if s <= rows[0][0]:
        return rows[0][1]
    if s >= rows[-1][0]:
        return rows[-1][1]
    i = max(k for k in range(len(rows) - 1) if rows[k][0] <= s)
    a, b, c, d = (rows[min(max(k, 0), len(rows) - 1)][1] for k in (i - 1, i, i + 1, i + 2))
    t = (s - rows[i][0]) / (rows[i + 1][0] - rows[i][0])
    return 0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t ** 3)


def radius(s):
    return _interp(s, RADII)


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
        P["edge"] = _tones(L, "edge", "#B9E1FB", "#D8F0FF")
    elif look == "Striped":
        P["body"] = _tones(L, "body", "#F7F5EF", "#FFFFFF")
        P["blue"] = _tones(L, "blue", "#3D7DE0", "#6CA2F2")
        P["red"] = _tones(L, "red", "#E8453C", "#FF7468")
    elif look == "Beach":
        P["body"] = _tones(L, "body", "#FFCB2E", "#FFE36E")
        P["orange"] = _tones(L, "orange", "#FF8A2A", "#FFAA5C")
        P["teal"] = _tones(L, "teal", "#1FB3AE", "#52D6CF")
        P["hem"] = _tones(L, "hem", "#FFF6DD", "#FFFFFF")
        P["sun"] = hexcol("towel_beach_sun", "#FFE14D")
        P["ray"] = hexcol("towel_beach_ray", "#FF7A1F")
    elif look == "Spa":
        P["body"] = _tones(L, "body", "#FBF7F8", "#FFFFFF")
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
        P["tassel"] = _tones(L, "tassel", "#F2BE36", "#FFE07A")
        P["cord"] = hexcol("towel_royal_tassel_cord", "#C08420")
    P["ink"] = hexcol(f"towel_{L}_ink", "#2A1838")
    return P


# per look:
#   cols   face column of a strand (0 = just after the groove ... PER - 1 = just before it) -> family:
#          helical stripes (the terry hem running beside the groove, candy stripes)
#   bands  (s from, s to, family): rings across the roll (the towel's border stripes); win over cols
#   wave   (amplitude, waves round) makes the band edges wavy
#   flap   (from, to, family) stripes across the folded flap, measured from its free end
#   tip    family of the tip bulb; badge; fluffy (Spa); tassel (Royal)
LOOKS = {
    "Plain": dict(cols={0: "edge"}, bands=[(0.8, 0.88, "hem"), (0.95, 1.03, "hem"), (2.92, 2.99, "hem"),
                                           (3.05, 3.12, "hem")],
                  flap=[(0.07, 0.12, "hem"), (0.17, 0.22, "hem")], tip="body"),
    "Striped": dict(cols={1: "blue", 2: "blue", 4: "red", 5: "red"}, bands=[],
                    flap=[(0.06, 0.12, "red"), (0.16, 0.22, "blue")], tip="red"),
    "Beach": dict(cols={0: "hem"}, bands=[(0.78, 0.86, "orange"), (2.15, 2.5, "teal"), (2.5, 2.58, "hem"),
                                          (2.58, 9.0, "teal")], wave=(0.06, 3),
                  flap=[(0.06, 0.12, "teal"), (0.16, 0.21, "orange")], tip="teal", badge="sun"),
    "Spa": dict(cols={0: "hem"}, bands=[(0.78, 0.9, "hem"), (2.95, 3.06, "hem")], flap=[(0.0, 0.1, "hem")],
                tip="hem", badge="flower", fluffy=True),
    "Sports": dict(cols={2: "hem", 3: "hem"}, bands=[(0.78, 0.92, "hem")],
                   flap=[(0.07, 0.12, "hem"), (0.17, 0.22, "hem")], tip="hem", badge="star"),
    "Champion": dict(cols={0: "hem"}, bands=[(0.78, 0.86, "hem"), (2.95, 3.03, "hem")],
                     flap=[(0.0, 0.06, "hem"), (0.12, 0.16, "hem")], tip="hem", badge="star"),
    "Royal": dict(cols={0: "hem"}, bands=[(0.78, 0.84, "hem"), (0.9, 0.96, "hem"), (2.95, 3.01, "hem")],
                  flap=[(0.0, 0.06, "hem"), (0.12, 0.16, "hem")], tip="hem", badge="crown", tassel=True),
}


# ---------------------------------------------------------------- mesh helpers
def _outward(bm):
    """Turns a closed mesh's faces outward (by its signed volume)."""
    vol = 0.0
    for f in bm.faces:
        vs = [v.co for v in f.verts]
        for i in range(1, len(vs) - 1):
            vol += vs[0].dot(vs[i].cross(vs[i + 1]))
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])


def _iso_cut(bm, vals, cuts):
    """Splits the faces of `bm` along the iso-lines vals == c for every c in `cuts` (vals: vert ->
    float, extended to the new verts), so a colour step drawn at c is a clean curve instead of a
    stair of whole faces (as props/slippers.py does). The surface itself is unchanged."""
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


def _tone(tones, nz):
    if isinstance(tones, int):
        return tones
    return tones[0] if nz > TONE_CUT else tones[1]


def _loft(rings, cap0=None, cap1=None):
    """bmesh from rings of equal size (lists of Vectors), closed round; optional pole points."""
    bm = bmesh.new()
    vr = [[bm.verts.new(p) for p in ring] for ring in rings]
    n = len(rings[0])
    for a, b in zip(vr, vr[1:]):
        for j in range(n):
            k = (j + 1) % n
            bm.faces.new((a[j], a[k], b[k], b[j]))
    for pole, ring in ((cap0, vr[0]), (cap1, vr[-1])):
        if pole is not None:
            pv = bm.verts.new(pole)
            for j in range(n):
                bm.faces.new((ring[j], ring[(j + 1) % n], pv))
    _outward(bm)
    # twisted quads aren't flat: split each along its better diagonal (else the silhouette saws)
    bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
    bm.normal_update()
    return bm


# ---------------------------------------------------------------- the roll
class Roll:
    """The twisted roll's surface: ring stations along s = -y, the twist phase and the radius."""

    def __init__(self, fluffy=False):
        self.fluffy = fluffy
        self.s0 = -Y_BACK
        self.s_tip = S_TIP
        # twist phase, integrated on a fine grid
        self.grid = [self.s0 - 0.3 + 0.01 * i for i in range(int((self.s_tip - self.s0 + 0.6) / 0.01) + 2)]
        ph, acc = [], 0.0
        for i, s in enumerate(self.grid):
            if i:
                acc += TWIST / (radius(s) + TWIST_R0) * 0.01
            ph.append(acc)
        self.ph = ph

    def phase(self, s):
        k = min(max(int((s - self.grid[0]) / 0.01), 0), len(self.grid) - 2)
        t = (s - self.grid[k]) / 0.01
        return self.ph[k] * (1 - t) + self.ph[k + 1] * t

    def groove(self, s):
        """Groove depth at s: full along the roll, fading out on the rounded ends."""
        g = GROOVE * _smooth(self.s0 - 0.2, self.s0 + 0.05, s) * (1.0 - _smooth(3.35, 3.7, s))
        return g * (1.15 if self.fluffy else 1.0)

    def profile(self, u):
        """0 in the groove, 1 on the strand's crest."""
        return math.sin(math.pi * u) ** (0.36 if self.fluffy else 0.42)

    def lump(self, s, th):
        k = _smooth(self.s0, self.s0 + 0.4, s) * (1.0 - _smooth(3.2, 3.6, s))
        w = math.sin(2 * math.pi * s / 0.83 + 0.7) * math.sin(2 * math.pi * s / 1.37 + 2.1)
        if self.fluffy:      # extra fluffy: puffs all over, not just along the roll
            w += 1.4 * math.sin(2 * th + 9.0 * s) * math.sin(6.0 * s - th + 1.0)
        return 1.0 + LUMP * k * w

    def point(self, s, j, n, scale=1.0, extra=0.0):
        """Vertex j of n round the ring at s (scale: the end caps' shrink)."""
        th = 2 * math.pi * j / n + self.phase(s)
        u = (LOBES * j / n) % 1.0
        r = radius(s) * (1.0 + self.groove(s) * (self.profile(u) - 1.0)) * self.lump(s, th)
        if self.fluffy:
            r *= 1.1
        r = (r + extra) * scale
        return Vector((r * math.cos(th), -s, r * math.sin(th)))

    def column(self, p):
        """Face column (0..PER-1 of a strand) of the point p on the roll."""
        s = -p.y
        th = math.atan2(p.z, p.x) - self.phase(s)
        u = (LOBES * th / (2 * math.pi)) % 1.0
        return min(int(u * PER), PER - 1)

    def stations(self, step, e_tip=0.0):
        """[(s, scale)] - the back cap (by angle), the roll, the tip bulb's cap - and the two poles.
        e_tip: the tip cap's radius change (the hull's thinner ink)."""
        rb = radius(self.s0)
        out = [(self.s0 - rb * math.cos(a), math.sin(a)) for a in (math.radians(d) for d in (28, 50, 70))]
        L = (self.s_tip - R_TIP) - self.s0
        n = max(int(L / step), 2)
        out += [(self.s0 + L * i / n, 1.0) for i in range(n + 1)]
        rt = R_TIP + e_tip
        out += [(self.s_tip - R_TIP + rt * math.sin(a), math.cos(a)) for a in (math.radians(d) for d in (35, 62, 80))]
        return out, (self.s0 - rb), self.s_tip - R_TIP + rt

    def mesh(self, n, step, extra_fn=None):
        st, s_back, s_tip = self.stations(step, extra_fn(self.s_tip) if extra_fn else 0.0)
        rings = [[self.point(s, j, n, sc, extra_fn(s) if extra_fn else 0.0) for j in range(n)] for s, sc in st]
        return _loft(rings, Vector((0, -s_back, 0)), Vector((0, -s_tip, 0)))


def _band_value(look, p):
    """The field the ring bands are cut along: s, made wavy round the roll for a `wave` look."""
    amp, k = LOOKS[look].get("wave", (0.0, 0))
    return -p.y + amp * math.sin(k * math.atan2(p.z, p.x)) if amp else -p.y


def _roll_piece(roll, P, look):
    spec = LOOKS[look]
    bm = roll.mesh(N_AROUND, RING_STEP)
    vals = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, vals, (TONE_CUT,))
    bands = spec["bands"]
    cuts = sorted({x for a, b, _f in bands for x in (a, b) if x < S_TIP} | {S_TIP - R_TIP * 1.1})
    bv = {v: _band_value(look, v.co) for v in bm.verts}
    _iso_cut(bm, bv, cuts)
    tip_s = S_TIP - R_TIP * 1.1
    fp = []
    for f in bm.faces:
        c = f.calc_center_median()
        b = _band_value(look, c)
        fam = spec["cols"].get(roll.column(c), "body")
        for a0, a1, fm in bands:
            if a0 <= b < a1:
                fam = fm
        if b >= tip_s:
            fam = spec.get("tip", fam)
        nz = sum(vals.get(v, 0.0) for v in f.verts) / len(f.verts)
        fp.append(_tone(P[fam], nz))
    p = K.Piece(K._bm_to_mesh(bm, "roll"), fp, False, True, "roll")
    p.rig = ("skin",)
    return p


def _roll_hull(roll):
    """The roll's outline hull (same columns and rings as the roll, without the colour cuts), its
    ink thinning from OUT_W at the handle to TIP_W at the tip: K.finish inflates it by OUT_W, so it
    is built that much smaller where the ink is thinner."""
    def extra(s):
        return (TIP_W - OUT_W) * _smooth(0.6, roll.s_tip, s)
    bm = roll.mesh(N_AROUND, RING_STEP, extra)
    p = K.Piece(K._bm_to_mesh(bm, "rollhull"), K.OUTLINE, True, True, "rollhull")
    p.rig = ("skin",)
    return p


# ---------------------------------------------------------------- the folded flap
FLAP_A = 0.32           # half width (along the surface)
FLAP_B = 0.12           # half thickness
FLAP_GAP = -0.05        # sunk into the roll a little: no gap under it
FLAP_ROUND = 0.16       # the free end's rounding (path length)


def _flap_frame(t, d0):
    """Path parameter t (from the flap's free end) -> (axis point, outward normal N, distance d)."""
    la = Y_BACK - Y_FLAP
    if t <= la:
        return Vector((0.0, Y_FLAP + t, 0.0)), Vector((0.0, 0.0, 1.0)), d0
    t -= la
    lb = math.pi * d0
    if t <= lb:
        a = t / d0
        return Vector((0.0, Y_BACK, 0.0)), Vector((0.0, math.sin(a), math.cos(a))), d0
    t -= lb
    k = _smooth(0.0, 0.3, t)
    return Vector((0.0, Y_BACK - t, 0.0)), Vector((0.0, 0.0, -1.0)), d0 - 0.13 * k


def _flap_piece(P, look):
    rb = radius(-Y_BACK)
    d0 = rb + FLAP_B + FLAP_GAP
    la, lb, lc = Y_BACK - Y_FLAP, math.pi * d0, 0.3
    total = la + lb + lc
    stripes = LOOKS[look]["flap"]
    # stations: rounded free end, every stripe boundary, then evenly
    ts = {0.01, 0.035, 0.07, 0.11}
    for a, b, _fam in stripes:
        ts.update((a, b))
    t = 0.16
    while t < total - 0.02:
        ts.add(round(t, 4))
        t += 0.14
    ts = sorted(x for x in ts if 0.0 < x < total - 0.01)
    M = 12
    sec = []
    for k in range(M):
        ph = 2 * math.pi * k / M
        c, s = math.cos(ph), math.sin(ph)
        sec.append((math.copysign(abs(c) ** 0.75, c), math.copysign(abs(s) ** 0.85, s)))
    X = Vector((1.0, 0.0, 0.0))
    rings = []
    for t in ts:
        axis, N, d = _flap_frame(t, d0)
        e0 = math.sqrt(max(0.0, 1.0 - (1.0 - min(t, FLAP_ROUND) / FLAP_ROUND) ** 2))   # rounded free end
        e1 = 1.0 - _smooth(total - lc, total, t)                                # tucked in under the roll
        thin = 0.45 + 0.55 * _smooth(0.0, 0.45, t)                              # the fabric end is thinner
        a, b = FLAP_A * e0 * (0.35 + 0.65 * e1), FLAP_B * thin * (0.6 + 0.4 * e0) * max(e1, 0.15)
        d = d - 0.07 * (1.0 - _smooth(0.0, 0.35, t))                           # the free end lies pressed on the roll
        ring = []
        for x, n in sec:
            beta = (x * a) / d
            ring.append(axis + (d + n * b) * (math.cos(beta) * N + math.sin(beta) * X))
        rings.append(ring)
    a0, N0, d_0 = _flap_frame(0.0, d0)
    a1, N1, d_1 = _flap_frame(total, d0)
    bm = _loft(rings, a0 + N0 * (d_0 - 0.07) + Vector((0, -0.004, 0)), a1 + N1 * (d_1 - 0.02))
    vals = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, vals, (TONE_CUT,))
    fp = []
    for f in bm.faces:
        c = f.calc_center_median()
        # the face's path distance: along the top strand it is y - Y_FLAP
        tt = c.y - Y_FLAP if c.z > 0.05 and c.y < Y_BACK else 9.0
        fam = "body"
        for a, b, fm in stripes:
            if a <= tt <= b:
                fam = fm
        nz = sum(vals[v] for v in f.verts) / len(f.verts)
        fp.append(_tone(P[fam], nz))
    p = K.Piece(K._bm_to_mesh(bm, "flap"), fp, True, True, "flap")
    p.rig = ("bone", "Seg1")
    return p


# ---------------------------------------------------------------- badges (sewn-on patches on top of the roll)
Y_BADGE = -1.2


def _star2d(r_out, r_in, n=5, rot=0.0):
    pts = []
    for i in range(2 * n):
        r = r_out if i % 2 == 0 else r_in
        a = math.pi / 2 + rot + math.pi * i / n
        pts.append((r * math.cos(a), r * math.sin(a)))
    return pts


def _circle2d(cx, cy, r, n=12, sx=1.0, rot=0.0):
    out = []
    for i in range(n):
        a = 2 * math.pi * i / n
        x, y = r * sx * math.cos(a), r * math.sin(a)
        out.append((cx + x * math.cos(rot) - y * math.sin(rot), cy + x * math.sin(rot) + y * math.cos(rot)))
    return out


def _grow(pts, d):
    """Polygon pushed out by ~d from its centroid (the ink border under a patch)."""
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    out = []
    for x, y in pts:
        l = math.hypot(x - cx, y - cy)
        k = (l + d) / max(l, 1e-6)
        out.append((cx + (x - cx) * k, cy + (y - cy) * k))
    return out


def _patch(pts, pal, h0, h1, y_c, roll, name, rig, centre=None, solid=True):
    """A flat 2D star-shaped polygon `pts` (a = sideways, b = toward the tip) wrapped onto the top
    of the roll at y_c, h1 above the strands' crest, fan-triangulated; `solid`: with side walls down
    to h0 (inside the roll, so no bottom), else just the top (a layer lying on another one)."""
    r0 = radius(-y_c)
    cx = sum(p[0] for p in pts) / len(pts) if centre is None else centre[0]
    cy = sum(p[1] for p in pts) / len(pts) if centre is None else centre[1]

    def wrap(a, b, h):
        y = y_c - b
        r = radius(-y) + h
        th = math.pi / 2 + a / r0
        return Vector((r * math.cos(th), y, r * math.sin(th)))
    bm = bmesh.new()
    top = [bm.verts.new(wrap(x, y, h1)) for x, y in pts]
    bot = [bm.verts.new(wrap(x, y, h0)) for x, y in pts] if solid else None
    ct = bm.verts.new(wrap(cx, cy, h1))
    n = len(pts)
    for j in range(n):
        k = (j + 1) % n
        bm.faces.new((top[j], top[k], ct))
        if solid:
            bm.faces.new((top[k], top[j], bot[j], bot[k]))
    bm.normal_update()
    if sum(f.normal.z for f in bm.faces) < 0:      # face up, out of the roll
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    p = K.Piece(K._bm_to_mesh(bm, name), pal, False, False, name)
    p.rig = rig
    return p


def _badge(kind, P, roll):
    """The look's sewn-on badge: an ink border patch with the coloured design on it."""
    anchor = Vector((0.0, Y_BADGE, radius(-Y_BADGE)))
    rig = ("stuck", anchor)
    base, top = -0.035, 0.03
    ink = P["ink"]
    out = []

    def layer(pts, pal, h, name="badge", centre=None):
        out.append(_patch(pts, pal, base, h, Y_BADGE, roll, name, rig, centre, solid=name == "badge_ink"))

    if kind == "star":
        r = 0.25 if "towel_sports_star" in K.PALETTE and P.get("star") == K.color("towel_sports_star") else 0.21
        star = _star2d(r, r * 0.46)
        layer(_grow(star, 0.035), ink, top - 0.012, "badge_ink")
        layer(star, P["star"], top)
        if "star_light" in P:          # a raised bevel highlight on the gold star
            layer([(x * 0.55, y * 0.55 + 0.012) for x, y in star], P["star_light"], top + 0.008)
    elif kind == "sun":
        rays = []
        for i in range(10):
            a = 2 * math.pi * i / 10 + math.pi / 2
            a1, a2 = a - 0.2, a + 0.2
            rays += [(0.13 * math.cos(a1), 0.13 * math.sin(a1)), (0.215 * math.cos(a), 0.215 * math.sin(a)),
                     (0.13 * math.cos(a2), 0.13 * math.sin(a2))]
        layer(_grow(rays, 0.03), ink, top - 0.012, "badge_ink")
        layer(rays, P["ray"], top - 0.004)
        disc = _circle2d(0.0, 0.0, 0.125, 16)
        layer(_grow(disc, 0.02), ink, top + 0.002, "badge_ink")
        layer(disc, P["sun"], top + 0.01)
    elif kind == "flower":
        petals = []
        for i in range(5):
            a = math.pi / 2 + 2 * math.pi * i / 5
            petals.append(_circle2d(0.085 * math.cos(a), 0.085 * math.sin(a), 0.07, 10, sx=0.75, rot=a + math.pi / 2))
        for pet in petals:
            layer(_grow(pet, 0.022), ink, top - 0.012, "badge_ink")
        for k, a in enumerate((-2.3, -0.84)):
            leaf = _circle2d(0.16 * math.cos(a), 0.16 * math.sin(a), 0.055, 10, sx=1.7, rot=a)
            layer(_grow(leaf, 0.02), ink, top - 0.014, "badge_ink")
            layer(leaf, P["leaf"], top - 0.006, "leaf")
        for pet in petals:
            layer(pet, P["petal"], top)
        c = _circle2d(0.0, 0.0, 0.05, 10)
        layer(_grow(c, 0.018), ink, top + 0.004, "badge_ink")
        layer(c, P["centre"], top + 0.012)
    elif kind == "crown":
        w, h = 0.2, 0.17
        crown = [(-w, -0.09), (w, -0.09), (w, 0.0), (w * 1.05, h), (w * 0.52, 0.05), (0.0, h * 1.1), (-w * 0.52, 0.05),
                 (-w * 1.05, h), (-w, 0.0)]
        ctr = (0.0, -0.01)
        layer(_grow(crown, 0.035), ink, top - 0.012, "badge_ink", centre=ctr)
        layer(crown, P["crown"], top, centre=ctr)
        band = [(-w * 0.92, -0.075), (w * 0.92, -0.075), (w * 0.92, -0.025), (-w * 0.92, -0.025)]
        layer(band, P["crown_light"], top + 0.006)
        for bx, by in ((-w * 1.05, h), (0.0, h * 1.1), (w * 1.05, h)):
            ball = _circle2d(bx, by + 0.01, 0.035, 8)
            layer(_grow(ball, 0.02), ink, top - 0.004, "badge_ink")
            layer(ball, P["crown"], top + 0.004)
        for gx in (-0.11, 0.0, 0.11):
            gem = _circle2d(gx, -0.05, 0.022, 8)
            layer(gem, P["gem"], top + 0.012, "gem")
        # the stitching: little dashes just inside the crown's edge
        edge = _grow(crown, -0.03)
        for i in range(len(edge)):
            x0, y0 = edge[i]
            x1, y1 = edge[(i + 1) % len(edge)]
            L = math.hypot(x1 - x0, y1 - y0)
            nd = max(1, int(L / 0.05))
            for q in range(nd):
                t0, t1 = (q + 0.2) / nd, (q + 0.65) / nd
                ax, ay = x0 + (x1 - x0) * t0, y0 + (y1 - y0) * t0
                bx2, by2 = x0 + (x1 - x0) * t1, y0 + (y1 - y0) * t1
                nx, ny = -(y1 - y0) / L * 0.007, (x1 - x0) / L * 0.007
                layer([(ax - nx, ay - ny), (bx2 - nx, by2 - ny), (bx2 + nx, by2 + ny), (ax + nx, ay + ny)],
                      P["stitch"], top + 0.01, "stitch")
    return out


# ---------------------------------------------------------------- the Royal's tassel
def _tassel(P):
    tip = Vector((0.0, (-S_TIP), 0.0))
    out = []
    bead = K.sphere(P["tassel"][1], 0.075, K.M((0, (-S_TIP) + 0.01, 0), scale=(1, 1.15, 1)), seg=10, rings=7,
                    name="tassel_bead")
    out.append(bead)
    # the skirt: a flared fluted tube hanging on along -Y
    rings, n = [], 16
    stations = [(0.04, 0.045), (0.09, 0.07), (0.17, 0.095), (0.27, 0.112), (0.36, 0.118), (0.4, 0.11)]
    for d, r in stations:
        ring = []
        for j in range(n):
            th = 2 * math.pi * j / n
            rr = r * (1.0 + 0.12 * math.cos(n / 2 * th) * _smooth(0.05, 0.2, d))
            ring.append(Vector((rr * math.cos(th), (-S_TIP) - 0.04 - d, rr * math.sin(th))))
        rings.append(ring)
    bm = _loft(rings, tip + Vector((0, -0.04, 0)), tip + Vector((0, -0.46, 0)))
    vals = {v: v.normal.z for v in bm.verts}
    fp = [_tone(P["tassel"], sum(vals[v] for v in f.verts) / len(f.verts)) for f in bm.faces]
    out.append(K.Piece(K._bm_to_mesh(bm, "tassel"), fp, True, True, "tassel"))
    collar = K.torus(P["cord"], 0.06, 0.022, K.M((0, (-S_TIP) - 0.08, 0), rot=(math.pi / 2, 0, 0)), seg=14, mseg=6,
                     name="tassel_collar")
    out.append(collar)
    for p in out:
        p.rig = ("bone", "Seg6")
    return out, Vector((0.0, (-S_TIP) - 0.46, 0.0))


# ---------------------------------------------------------------- the Spa's pom-pom
def _pompom(P):
    """A fluffy ball on the tip: a sphere with soft lumps (a few smooth lobes), so its outline is
    scalloped (like props/slippers.py's pom-pom)."""
    r, c = 0.16, Vector((0.0, -S_TIP - 0.04, 0.0))
    lobes = [Vector(d).normalized() for d in ((1, 0.2, 0.3), (-0.8, 0.4, 0.5), (0.1, 1, 0.2), (0.3, -0.2, 1),
                                              (-0.4, -0.9, 0.1), (0.5, 0.6, -0.6), (-0.6, 0.1, -0.7), (0.9, -0.6, -0.2),
                                              (-0.3, 0.8, 0.9), (0.2, -1, -0.5))]
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=10, v_segments=7, radius=1.0)
    for v in bm.verts:
        d = v.co.normalized()
        bump = sum(math.exp(-(1 - d.dot(l)) / 0.08) for l in lobes)
        v.co = c + d * r * (0.85 + 0.22 * min(1.0, bump))
    bm.normal_update()
    vals = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, vals, (TONE_CUT,))
    fp = [_tone(P["hem"], sum(vals[v] for v in f.verts) / len(f.verts)) for f in bm.faces]
    p = K.Piece(K._bm_to_mesh(bm, "pompom"), fp, True, True, "pompom")
    p.rig = ("bone", "Seg6")
    return p, Vector((0.0, -S_TIP - 0.04 - r, 0.0))


# ---------------------------------------------------------------- build
def build_towel(look):
    name = "Towel_" + look
    P = _palette(look)
    spec = LOOKS[look]
    roll = Roll(fluffy=spec.get("fluffy", False))
    pieces = [_roll_piece(roll, P, look), _flap_piece(P, look)]
    if spec.get("badge"):
        pieces += _badge(spec["badge"], P, roll)
    tip = Vector((0.0, -S_TIP, 0.0))
    if spec.get("tassel"):
        tp, tip = _tassel(P)
        pieces += tp
    if spec.get("fluffy"):
        pp, tip = _pompom(P)
        pieces.append(pp)
    body, outline = K.finish(pieces, name, outline_width=OUT_W, outline_only=[_roll_hull(roll)])
    # K.finish leaves the hull flat-shaded, so the GLB splits every face's corners into their own
    # vertices (~3x the skinned vertices); the ink needs no facets: share them
    outline.data.polygons.foreach_set("use_smooth", [True] * len(outline.data.polygons))
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission", "visible_volume_scatter"):
        if hasattr(outline, attr):  # preview only: the hull must not block light (it doesn't in Roblox)
            setattr(outline, attr, False)
    return [body, outline] + K.markers(name) + [items.grip(name, (0.0, 0.0, 0.0)), K.marker(name + "_Tip", tip)]


BUILDERS = {"Towel_" + look: (lambda look=look: build_towel(look)) for look in LOOKS}

# texture classes for tools/blender/texturing.py: the towels are soft terry cloth
MATERIALS = {"towel": "felt", "towel_spa": "fluff", "towel_royal_tassel": "rope", "towel_royal_crown": "felt",
             "towel_royal_gem": "glass"}


# ---------------------------------------------------------------- skeleton
def _field(y):
    """Seg weights along the towel at height y (toward the tip = smaller y)."""
    w = {"Seg1": 1.0}
    for k in range(1, 6):
        J, h = JOINTS[k], BLEND[k]
        if y <= J + h:
            t = _smooth(0.0, 1.0, (J + h - y) / (2 * h))
            w = {f"Seg{k}": 1.0 - t, f"Seg{k + 1}": t}
    return {b: v for b, v in w.items() if v > 0.0}


def _weights(tag, p):
    kind = tag[0] if tag else "skin"
    if kind == "bone":
        return {tag[1]: 1.0}
    if kind == "stuck":
        return _field(tag[1].y)
    return _field(p[1])


def rig(name, objs):
    """`<Name>_Rig`: Root at the grip + Seg1..Seg6 to the tip; skins the body and the outline."""
    body = objs[0]
    outline = next(o for o in objs if o.name == name + "_Outline")
    info = K.PIECE_MAP[name]
    W = [None] * len(body.data.vertices)
    for i, r in enumerate(info["body"]):
        if r is None:
            continue
        s, cnt = r
        tag = info["tags"][i]
        for k in range(cnt):
            W[s + k] = rigging._finalise(_weights(tag, body.data.vertices[s + k].co))
    assert all(w is not None for w in W), "body vertices without weights"
    WO = [None] * len(outline.data.vertices)
    for pi, s, n in info["outline"]:
        br = info["body"][pi]
        for k in range(n):
            if br is not None:
                WO[s + k] = W[br[0] + k]
            else:
                WO[s + k] = rigging._finalise(_weights(info["tags"][pi], outline.data.vertices[s + k].co))
    assert all(w is not None for w in WO), "outline vertices without weights"
    bones = {"Root": rigging.Bone("Root", None, (0, 0, 0), (0, -0.3, 0), "root")}
    heads = JOINTS + [-S_TIP]          # the same skeleton for every look (a tassel / pom-pom rides Seg6)
    for k in range(6):
        bones[f"Seg{k + 1}"] = rigging.Bone(f"Seg{k + 1}", "Root" if k == 0 else f"Seg{k}", (0, heads[k], 0),
                                            (0, heads[k + 1], 0), "seg", index=k + 1)
    ao = rigging.build_armature(name + "_Rig", bones)
    ao.matrix_world = body.matrix_world.copy()      # preview.py moves items apart before rigging
    rigging._skin(body, ao, W)
    rigging._skin(outline, ao, WO)
    return ao


# test poses for preview.py --pose (rigging.apply_pose: world axes; +X turns the towel down)
POSES = {
    "rest": {},
    "windup": {"Seg1": [((1, 0, 0), -25)], "Seg2": [((1, 0, 0), -30)], "Seg3": [((1, 0, 0), -35)],
               "Seg4": [((1, 0, 0), -35)], "Seg5": [((1, 0, 0), -30)], "Seg6": [((1, 0, 0), -25)]},
    "crack": {"Seg2": [((0, 0, 1), 25)], "Seg3": [((0, 0, 1), 30)], "Seg4": [((0, 0, 1), -40)],
              "Seg5": [((0, 0, 1), -45)], "Seg6": [((0, 0, 1), 40)]},
    "droop": {"Seg2": [((1, 0, 0), 35)], "Seg3": [((1, 0, 0), 30)], "Seg4": [((1, 0, 0), 18)],
              "Seg5": [((1, 0, 0), 10)], "Seg6": [((1, 0, 0), 6)]},
    # the clean limit: 45 degrees at every flexible joint (a 225 degree curl)
    "curl": {f"Seg{k}": [((1, 0, 0), 45)] for k in range(2, 7)},
}
