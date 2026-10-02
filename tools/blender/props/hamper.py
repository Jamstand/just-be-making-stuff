"""
props/hamper.py - the Hamper prop (ReplicatedStorage.MapMeshes.Hamper): a tall coiled-rope laundry
hamper whose hinged lid is propped open by the heap of socks bursting out of it. See
props/__init__.py for the conventions every prop follows.

No concept art shows it, so it is designed to sit in docs/concept/bedroom_keyframe.png: chunky soft
toy shapes, flat 2-3 tone colours, thick ink lines. The body is a rounded-square, slightly flared
basket of stacked cream rope coils (each coil a lit top strip, a base face and a shaded underside)
with two sky-blue coil bands, a fat rolled rim and a darker foot coil (a coiled hamper, so it never
reads as the Basket's tan wicker). Like the Basket's weave, the bumpy coils draw no outline of their
own: a smooth outline-only envelope gives the wall one clean silhouette line. The lid - a squircle
slab with a rolled edge, concentric coil rings painted on its top, a sky-blue fabric lining underneath
and a blue knob - is hinged at the back and propped open by the heap (a rolled-up pair touches it).
The heap: a core painted as a big lavender / purple striped sock, domed up under the lid, with short
bunched-up socks in every colour lying all over it and a rolled-up pair on top.
The socks (one build for all of them: a flattened tube along a smooth path, ribbed cuff, heel patch on
the outside of the bend, rounded toe, dark opening) come in stripes, polka dots and argyle: stripes
are rings of the tube itself and argyle diamonds are cut into the mesh along iso-lines of the sock's
own (length, angle) coordinates, so their edges are crisp; polka dots are little discs bent onto its
surface. A red / cream striped sock hangs over the front rim, its foot kicking sideways; a purple and
yellow argyle sock flops out of the gap under the lid over the front rim; a green sock with yellow
dots hangs down the left side, a pink one with white dots over the right; a blue-striped sock curls
over the heap; an orange striped sock lies on the floor in front.

Units: 1 unit = 10 studs. Map fits the model uniformly into 90 x 110 x 90 studs (W x H x D); the
model is about 7.7 x 10.9 x 8.1 units (W x H x D). Origin = floor centre, front faces -Y.
"""
import math
import random
import bmesh
import numpy as np
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol

NAME = "Hamper"

ROPE = (hexcol("hamper_rope_light", "#FFF4DC"),   # top strip of each coil, rim top
        hexcol("hamper_rope", "#F1DDB6"),         # coil faces
        hexcol("hamper_rope_shade", "#CDB083"),   # coil undersides, grooves
        hexcol("hamper_rope_deep", "#A88A60"))    # foot coil underside
BAND = (hexcol("hamper_band_light", "#A8DBFF"), hexcol("hamper_band", "#6FB7F0"),
        hexcol("hamper_band_shade", "#4C8FD0"))
LID_IN = hexcol("hamper_lid_inside", "#8EC3EE")   # the lid's underside: sky-blue fabric lining
HEAP = (hexcol("hamper_heap_light", "#B7A0EE"), hexcol("hamper_heap", "#8A68D2"))  # the big sock under the heap
# socks
SK_IN = hexcol("hamper_sock_inner", "#3A2F4E")    # every sock's opening
SK = {
    "red": (hexcol("hamper_sock_red", "#E8504C"), hexcol("hamper_sock_red_dark", "#B9343C")),
    "cream": (hexcol("hamper_sock_cream", "#FFF0D8"), hexcol("hamper_sock_cream_dark", "#E3CDB0")),
    "green": (hexcol("hamper_sock_green", "#5CC85A"), hexcol("hamper_sock_green_dark", "#3A9A45")),
    "yellow": (hexcol("hamper_sock_yellow", "#FFD84A"), hexcol("hamper_sock_yellow_dark", "#E9AE2C")),
    "purple": (hexcol("hamper_sock_purple", "#9B6CE0"), hexcol("hamper_sock_purple_dark", "#6E45B4")),
    "pink": (hexcol("hamper_sock_pink", "#FF8FB8"), hexcol("hamper_sock_pink_dark", "#E0608F")),
    "blue": (hexcol("hamper_sock_blue", "#5D9BEA"), hexcol("hamper_sock_blue_dark", "#3C6FC4")),
    "orange": (hexcol("hamper_sock_orange", "#FF9A3C"), hexcol("hamper_sock_orange_dark", "#DB6A2A")),
    "white": (hexcol("hamper_sock_white", "#FBF8F2"), hexcol("hamper_sock_white_dark", "#DDD6CC")),
    "teal": (hexcol("hamper_sock_teal", "#3CC7B5"), hexcol("hamper_sock_teal_dark", "#25998C")),
}

OUTLINE_W = 0.12          # ~1.1% of the model's height

# ---- body (units)
SQ_P = 3.6                # squircle exponent of the cross-section (2 = circle, large = square)
HW0, HW1 = 2.65, 3.0      # half width at the bottom / top of the coiled wall
Z0, Z1 = 0.42, 6.62       # coiled wall
COILS = 7
COIL_A = 0.1              # how far a coil stands out of the grooves
BAND_COILS = (1, 5)       # the sky-blue coils
COLS = 24                 # vertices round the body
RIM_Z, RIM_R = 6.86, 0.34
FOOT_Z, FOOT_R = 0.3, 0.3
# ---- lid
LID_HW = 3.27             # half size of the lid
LID_T = 0.36              # its thickness (the rolled edge is a little fatter)
HINGE = Vector((0.0, 3.13, 7.22))
LID_OPEN = math.radians(31)


# ---------------------------------------------------------------- helpers
def _iso_cut(bm, vals, cuts, skip=None):
    """Splits the faces of `bm` along the iso-lines vals == c for every c in `cuts` (vals: vert ->
    float, extended to the new verts), so a colour step drawn at c is a clean curve instead of a
    stair of whole faces. The surface itself is unchanged (new verts sit on existing edges). Edges
    touching a vert in `skip` are left alone. Returns the new verts with the edge they split
    ((a, b, t) per new vert) for other fields."""
    made = {}
    skip = skip or set()
    for c in cuts:
        for v in bm.verts:
            if abs(vals[v] - c) < 1e-5:
                vals[v] = c + 1e-5
        new = set()
        for e in list(bm.edges):
            a, b = e.verts
            if a in skip or b in skip:
                continue
            va, vb = vals[a], vals[b]
            if (va - c) * (vb - c) < 0:
                t = (c - va) / (vb - va)
                _, nv = bmesh.utils.edge_split(e, a, t)
                vals[nv] = c
                made[nv] = (a, b, t)
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
    return made


def _outward(bm):
    """Turns a closed mesh's faces outward (by its signed volume)."""
    vol = 0.0
    for f in bm.faces:
        vs = [v.co for v in f.verts]
        for i in range(1, len(vs) - 1):
            vol += vs[0].dot(vs[i].cross(vs[i + 1]))
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])


def _tone(cols, nz, up=0.55, down=-0.35):
    return cols[0] if nz > up else (cols[2] if nz < down else cols[1])


def _no_bounce(outline):
    """Preview only (Cycles ray flags, not exported): the inverted hull must not block bounce light."""
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission"):
        if hasattr(outline, attr):
            setattr(outline, attr, False)


# ---------------------------------------------------------------- the squircle
def _sq_raw(t):
    c, s = math.cos(t), math.sin(t)
    e = 2.0 / SQ_P
    return math.copysign(abs(c) ** e, c), math.copysign(abs(s) ** e, s)


_TS = np.linspace(0.0, math.tau, 2001)
_PTS = np.array([_sq_raw(t) for t in _TS])
_CUM = np.concatenate(([0.0], np.cumsum(np.linalg.norm(np.diff(_PTS, axis=0), axis=1))))


def _sq(u):
    """Unit squircle point and its outward 2D normal at arc-length fraction u (0 = +X, CCW)."""
    t = float(np.interp((u % 1.0) * _CUM[-1], _CUM, _TS))
    x, y = _sq_raw(t)
    nx = math.copysign(abs(x) ** (SQ_P - 1), x)
    ny = math.copysign(abs(y) ** (SQ_P - 1), y)
    ln = math.hypot(nx, ny) or 1.0
    return Vector((x, y, 0.0)), Vector((nx / ln, ny / ln, 0.0))


def _hw(z):
    return HW0 + (HW1 - HW0) * (z - Z0) / (Z1 - Z0)


def _wall(u, z, lift=0.0):
    """Point on the (groove-level) wall at arc fraction u, height z, `lift` out along the normal."""
    p, n = _sq(u)
    return Vector((0, 0, z)) + p * _hw(z) + n * lift, n


# ---------------------------------------------------------------- the basket
def _body():
    """The coiled wall: each coil = groove, lower shoulder, coil face, upper shoulder."""
    prof = []   # (z, offset, kind of the face ABOVE this ring)
    h = (Z1 - Z0) / COILS
    for i in range(COILS):
        z = Z0 + i * h
        prof += [(z, 0.0, ("low", i)), (z + 0.3 * h, COIL_A, ("face", i)), (z + 0.7 * h, COIL_A, ("up", i))]
    prof.append((Z1, 0.0, None))
    bm = bmesh.new()
    rings = []
    for z, off, _k in prof:
        ring = []
        for j in range(COLS):
            p, _n = _wall(j / COLS, z, off)
            ring.append(bm.verts.new(p))
        rings.append(ring)
    kinds = []
    for i in range(len(rings) - 1):
        for j in range(COLS):
            k = (j + 1) % COLS
            bm.faces.new((rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]))
            kinds.append(prof[i][2])
    _outward(bm)
    pal = []
    for kind, i in kinds:
        cols = BAND if i in BAND_COILS else ROPE
        if i == 0:
            cols = (ROPE[1], ROPE[2], ROPE[3])
        pal.append(cols[0] if kind == "up" else (cols[1] if kind == "face" else cols[2]))
    return K.Piece(K._bm_to_mesh(bm, "coils"), pal, outline=False, smooth=True, name="coils")


def _envelope():
    """Outline-only shell round the coils' faces (closed, smooth): one clean silhouette line."""
    bm = bmesh.new()
    zs = (Z0 - 0.05, (Z0 + Z1) / 2, Z1 + 0.1)
    rings = [[bm.verts.new(_wall(j / COLS, z, COIL_A * 0.92)[0]) for j in range(COLS)] for z in zs]
    for i in range(len(rings) - 1):
        for j in range(COLS):
            k = (j + 1) % COLS
            bm.faces.new((rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]))
    bm.faces.new(rings[0][::-1])
    bm.faces.new(rings[-1])
    _outward(bm)
    return K.Piece(K._bm_to_mesh(bm, "envelope"), K.OUTLINE, outline=True, smooth=True, name="envelope")


def _ring_tube(z, r, lift, pal, name, sides=8, hw=None):
    """A fat rope tube right round the squircle at height z (centre `lift` out of the wall)."""
    bm = bmesh.new()
    rings = []
    for j in range(COLS):
        u = j / COLS
        p, n = _sq(u)
        c = Vector((0, 0, z)) + p * (hw if hw is not None else _hw(z)) + n * lift
        rings.append([bm.verts.new(c + (n * math.cos(a) + Vector((0, 0, 1)) * math.sin(a)) * r)
                      for a in (i / sides * math.tau for i in range(sides))])
    for j in range(COLS):
        a, b = rings[j], rings[(j + 1) % COLS]
        for i in range(sides):
            k = (i + 1) % sides
            bm.faces.new((a[i], b[i], b[k], a[k]))
    _outward(bm)
    bm.normal_update()
    fp = [pal(f.normal) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, name), fp, outline=True, smooth=True, name=name)


def _floor_disc(z, hw, pal, name, up=True):
    bm = bmesh.new()
    c = bm.verts.new((0, 0, z))
    ring = [bm.verts.new(Vector((0, 0, z)) + _sq(j / COLS)[0] * hw) for j in range(COLS)]
    for j in range(COLS):
        f = bm.faces.new((c, ring[j], ring[(j + 1) % COLS]))
        if (f.normal.z > 0) != up:
            f.normal_flip()
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline=False, smooth=False, name=name)


def _basket():
    out = [_body()]
    out.append(_ring_tube(RIM_Z, RIM_R, COIL_A * 0.5, lambda n: _tone(ROPE, n.z, 0.45, -0.45), "rim", sides=7))
    out.append(_ring_tube(FOOT_Z, FOOT_R, COIL_A * 0.6, lambda n: _tone((ROPE[1], ROPE[2], ROPE[3]), n.z, 0.45, -0.3),
                          "foot", sides=6, hw=_hw(Z0)))
    out.append(_floor_disc(0.06, _hw(Z0), ROPE[3], "bottom", up=False))
    return out


# ---------------------------------------------------------------- the lid
def _lid_matrix():
    return Matrix.Translation(HINGE) @ M(rot=(-LID_OPEN, 0, 0))


def _lid():
    """Squircle slab hinged at its back edge: domed top with painted concentric coil rings, rolled
    edge, flat underside, a blue knob near the front."""
    m = _lid_matrix()
    # lid-local: centre at (0, -LID_HW, 0); top z = LID_T (+ a slight dome), underside z = 0
    cy = -LID_HW
    bm = bmesh.new()
    nr = 3
    rho = {}
    rings = []
    for i in range(1, nr + 1):
        r = i / nr
        ring = []
        for j in range(COLS):
            p, _n = _sq(j / COLS)
            q = Vector((p.x * LID_HW * r * 0.94, cy + p.y * LID_HW * r * 0.94, LID_T + 0.22 * (1 - r * r)))
            v = bm.verts.new(q)
            rho[v] = r
            ring.append(v)
        rings.append(ring)
    c = bm.verts.new((0, cy, LID_T + 0.22))
    rho[c] = 0.0
    bot = bm.verts.new((0, cy, 0.0))
    rho[bot] = 2.0
    under = []
    for j in range(COLS):
        p, _n = _sq(j / COLS)
        v = bm.verts.new((p.x * LID_HW * 0.94, cy + p.y * LID_HW * 0.94, 0.0))
        rho[v] = 2.0
        under.append(v)
    for j in range(COLS):
        k = (j + 1) % COLS
        bm.faces.new((c, rings[0][j], rings[0][k]))
        for i in range(nr - 1):
            bm.faces.new((rings[i][j], rings[i + 1][j], rings[i + 1][k], rings[i][k]))
        bm.faces.new((rings[-1][j], under[j], under[k], rings[-1][k]))
        bm.faces.new((bot, under[k], under[j]))
    _outward(bm)
    # concentric coil rings painted on the top: crisp bands cut along rho
    cuts = (0.2, 0.38, 0.56, 0.74)
    _iso_cut(bm, rho, cuts)
    pal = []
    for f in bm.faces:
        r = sum(rho[v] for v in f.verts) / len(f.verts)
        if r > 1.5:
            pal.append(LID_IN)
        else:
            band = sum(1 for cc in cuts if r > cc)
            pal.append(BAND[0] if band == 2 else (ROPE[0] if band % 2 == 0 else ROPE[1]))
    me = K._bm_to_mesh(bm, "lid")
    me.transform(m)
    out = [K.Piece(me, pal, outline=True, smooth=True, name="lid")]
    # the rolled edge
    edge = _ring_tube(0.0, LID_T * 0.62, 0.0, lambda n: ROPE[1], "lid_edge", sides=6, hw=LID_HW * 0.94)
    edge.mesh.transform(m @ Matrix.Translation((0, cy, LID_T * 0.5)))
    up = (m.to_3x3() @ Vector((0, 0, 1))).normalized()
    edge.face_pal = [ROPE[0] if f.normal.dot(up) > 0.5 else (LID_IN if f.normal.dot(up) < -0.5 else ROPE[1])
                     for f in edge.mesh.polygons]
    out.append(edge)
    knob = K.sphere(BAND[1], 0.32, m @ M((0, cy - LID_HW * 0.62, LID_T + 0.2), scale=(1.0, 1.0, 0.75)), seg=10, rings=6,
                    name="knob")
    knob.face_pal = [_tone(BAND, f.normal.dot(up), 0.6, -0.3) for f in knob.mesh.polygons]
    out.append(knob)
    return out


# ---------------------------------------------------------------- socks
def _catmull(ctrl, n=20):
    """Uniform Catmull-Rom through ctrl -> [(point, fractional control index)]."""
    P = [ctrl[0] * 2 - ctrl[1]] + list(ctrl) + [ctrl[-1] * 2 - ctrl[-2]]
    out = []
    for i in range(len(ctrl) - 1):
        p0, p1, p2, p3 = P[i], P[i + 1], P[i + 2], P[i + 3]
        for j in range(n):
            t = j / n
            pt = 0.5 * ((p1 * 2) + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t * t
                        + (p1 * 3 - p0 - p2 * 3 + p3) * t * t * t)
            out.append((pt, i + t))
    out.append((Vector(ctrl[-1]), len(ctrl) - 1.0))
    return out


def _sock(ctrl, hints, pat, width=0.44, thick=0.15, heel=None, step=0.24, sides=8, cuff=0.45, toe=0.5,
          name="sock"):
    """A sock along a smooth path through `ctrl` (cuff opening at the start, rounded toe at the end).

    hints[i] = the "lying on" normal at ctrl[i] (the sock's flat side faces it). heel = control index
    of the heel bend (its outside bulges a little and gets the heel patch). pat = dict(kind =
    "plain" | "stripes" | "dots" | "argyle", body = colour key, accent = colour key (cuff, heel, toe),
    plus "stripe" / "dot" / "diamond" colour key and sizes). Every colour edge is crisp: the cuff, toe
    and stripe edges are rings of the tube itself, the heel patch and the argyle diamonds are cut into
    the mesh along iso-lines of the sock's own (length, angle) coordinates (only on the side that
    shows), and polka dots are little discs bent onto it (see _dots). -> [sock piece(, dots piece)]"""
    ctrl = [Vector(c) for c in ctrl]
    dense = _catmull(ctrl)
    lens = [0.0]
    for i in range(1, len(dense)):
        lens.append(lens[-1] + (dense[i][0] - dense[i - 1][0]).length)
    L = lens[-1]

    def at(d):
        d = max(0.0, min(L, d))
        k = int(np.searchsorted(lens, d))
        k = max(1, min(k, len(lens) - 1))
        seg = lens[k] - lens[k - 1]
        u = (d - lens[k - 1]) / seg if seg > 1e-9 else 0.0
        return dense[k - 1][0].lerp(dense[k][0], u), dense[k - 1][1] + (dense[k][1] - dense[k - 1][1]) * u

    def hint_at(fi):
        i0 = min(int(math.floor(fi)), len(hints) - 1)
        i1 = min(i0 + 1, len(hints) - 1)
        return Vector(hints[i0]).normalized().lerp(Vector(hints[i1]).normalized(), fi - i0).normalized()

    def tangent(d):
        e = max(step * 0.5, 0.03)
        return (at(d + e)[0] - at(d - e)[0]).normalized()

    tip_len = width
    body_len = L - tip_len
    toe_s = L - toe
    kind = pat.get("kind", "plain")
    # rings: on every colour edge that runs round the sock (cuff, toe, stripes), so those need no
    # cuts, and evenly in between
    marks = {0.0, body_len, cuff, toe_s}
    if kind == "stripes":
        band = pat.get("band", 0.3)
        k = 1
        while cuff + k * band < toe_s - band * 0.3:
            marks.add(cuff + k * band)
            k += 1
    marks = sorted(m for m in marks if 0.0 <= m <= body_len)
    ds = []
    for a, b in zip(marks, marks[1:]):
        n = max(1, int(round((b - a) / step)))
        ds += [a + (b - a) * j / n for j in range(n)]
    ds.append(body_len)
    ds += [body_len + tip_len * math.sin((j / 4) * math.pi / 2) for j in range(1, 4)]
    heel_d = heel_out = None
    if heel is not None:
        best = min(range(len(dense)), key=lambda i: abs(dense[i][1] - heel))
        heel_d = lens[best]
        heel_out = (tangent(heel_d - width * 1.2) - tangent(heel_d + width * 1.2)).normalized()

    def surf(d, a):
        """The sock's surface at length d, angle a round it (pi/2 = the side away from what it lies
        on) -> (point, heel weight)."""
        p, fi = at(d)
        T = tangent(d)
        Wd = T.cross(hint_at(fi))
        if Wd.length < 1e-6:
            Wd = T.orthogonal()
        Wd.normalize()
        Nn = Wd.cross(T).normalized()
        sc = 1.0
        if d > body_len:
            u = (d - body_len) / tip_len
            sc = math.sqrt(max(0.0, 1 - u * u))
        if d < cuff:
            sc *= 1.06      # the ribbed cuff stands a little proud
        c, s = math.cos(a), math.sin(a)
        c2 = math.copysign(abs(c) ** (2 / 2.6), c)
        s2 = math.copysign(abs(s) ** (2 / 2.6), s)
        off = Wd * (c2 * width * sc) + Nn * (s2 * thick * sc)
        hw = 0.0
        if heel_d is not None:
            g = math.exp(-((d - heel_d) / (width * 0.9)) ** 2)
            dirn = off.normalized() if off.length > 1e-9 else off
            hw = max(0.0, dirn.dot(heel_out))
            off = off + dirn * (width * 0.28 * g * hw ** 1.5)
            hw = hw * math.exp(-((d - heel_d) / (width * 1.05)) ** 2)
        # the inside of a tight bend is squashed flat instead of folding through itself
        e = max(width * 0.5, step)
        kv = (tangent(min(d + e, L)) - tangent(max(d - e, 0.0))) / (2 * e)
        if kv.length > 1e-3:
            bn, lim = kv.normalized(), 0.8 / kv.length
            inward = off.dot(bn)
            if inward > lim:
                off = off - bn * (inward - lim)
        return p + off, hw

    bm = bmesh.new()
    S, A, HW = {}, {}, {}
    rings = []
    for d in ds:
        ring = []
        for k in range(sides):
            a = (k + 0.5) / sides * math.tau
            co, hw = surf(d, a)
            v = bm.verts.new(co)
            S[v], A[v], HW[v] = d, a, hw
            ring.append(v)
        rings.append(ring)
    for r in range(len(rings) - 1):
        for k in range(sides):
            k2 = (k + 1) % sides
            bm.faces.new((rings[r][k], rings[r][k2], rings[r + 1][k2], rings[r + 1][k]))
    bm.faces.new(list(reversed(rings[0])))
    pole = bm.verts.new(at(L)[0])
    S[pole], A[pole], HW[pole] = L, 0.0, 0.0
    for k in range(sides):
        bm.faces.new((rings[-1][k], rings[-1][(k + 1) % sides], pole))
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

    # ---- scalar fields cut into the mesh; new verts get (s, a, heel) interpolated along their edge
    def lerp_params(made):
        for nv, (a, b, t) in made.items():
            S[nv] = S[a] + (S[b] - S[a]) * t
            da = (A[b] - A[a] + math.pi) % math.tau - math.pi
            A[nv] = (A[a] + da * t) % math.tau
            HW[nv] = HW[a] + (HW[b] - HW[a]) * t

    def cut(field, levels, everywhere=False):
        """Cut the mesh along field == level; pattern fields stay out of the cuff and the toe."""
        def fld(v):
            if not everywhere and (S[v] < cuff - 1e-4 or S[v] > toe_s + 1e-4):
                return 9.0
            return field(v)
        vals = {v: fld(v) for v in bm.verts}
        skip = set() if everywhere else {v for v in bm.verts if math.sin(A[v]) < HIDDEN}
        made = _iso_cut(bm, vals, levels, skip)
        lerp_params(made)

    if heel_d is not None:
        cut(lambda v: HW[v], (0.45,))
    if kind == "argyle":
        n, dsz = pat.get("around", 4), pat.get("size", 0.5)
        cut(lambda v: math.sin(math.pi * ((S[v] - cuff) / dsz + n * A[v] / math.tau)), (0.0,))
        cut(lambda v: math.sin(math.pi * ((S[v] - cuff) / dsz - n * A[v] / math.tau)), (0.0,))
    # ---- colours
    body, accent = SK[pat["body"]], SK[pat.get("accent", pat["body"])]
    pal = []
    for f in bm.faces:
        if all(S[v] < 1e-6 for v in f.verts):
            pal.append(SK_IN)
            continue
        vs = list(f.verts)
        s = sum(S[v] for v in vs) / len(vs)
        hw = sum(HW[v] for v in vs) / len(vs)
        ca = sum(math.cos(A[v]) for v in vs if v is not pole)
        sa = sum(math.sin(A[v]) for v in vs if v is not pole)
        a = math.atan2(sa, ca) % math.tau
        if s < cuff:
            # ribbed cuff: thin alternating ribs round it
            pal.append(accent[0] if int(round(a / math.tau * sides * 2)) % 2 else accent[1])
            continue
        if s > toe_s or hw > 0.45:
            pal.append(accent[1] if pat.get("dark_accent", True) else accent[0])
            continue
        col = body[0]
        if kind == "stripes":
            if int(math.floor((s - cuff) / pat.get("band", 0.3))) % 2 == 0:
                col = SK[pat["stripe"]][0]
        elif math.sin(a) < HIDDEN:
            pass                # the side the sock lies on: no pattern (its mesh has no pattern cuts)
        elif kind == "argyle":
            n, dsz = pat.get("around", 4), pat.get("size", 0.5)
            u1 = (s - cuff) / dsz + n * a / math.tau
            u2 = (s - cuff) / dsz - n * a / math.tau
            if (math.floor(u1) + math.floor(u2)) % 2 == 0:
                col = SK[pat["diamond"]][0]
        pal.append(col)
    p = K.Piece(K._bm_to_mesh(bm, name), pal, outline=True, smooth=True, name=name)
    p.flat_faces = [i for i, c in enumerate(pal) if c == SK_IN]
    out = [p]
    if kind == "dots":
        out.append(_dots(surf, at, cuff, toe_s, pat, name + "_dots"))
    return out


def _dots(surf, at, s0, s1, pat, name, seg=8, lift=0.018):
    """Polka dots on a sock's upper side: little discs bent onto its surface (rows of one and two
    dots in turn), skipping the heel patch."""
    r, gap = pat.get("r", 0.11), pat.get("gap", 0.4)
    bm = bmesh.new()
    row = 0
    d = s0 + gap * 0.55
    while d < s1 - gap * 0.4:
        for x in ((0.0,) if row % 2 == 0 else (-0.5, 0.5)):
            a = math.acos(math.copysign(abs(x) ** 1.3, x))
            q, hw = surf(d, a)
            if hw > 0.25:
                continue
            da = (surf(d, a + 0.03)[0] - surf(d, a - 0.03)[0]) / 0.06
            dd = (surf(d + 0.03, a)[0] - surf(d - 0.03, a)[0]) / 0.06
            n = dd.cross(da).normalized()
            if n.dot(q - at(d)[0]) < 0:
                n = -n
            c = bm.verts.new(q + n * lift)
            rim = []
            for j in range(seg):
                t = j / seg * math.tau
                qq = surf(d + r * math.cos(t) / max(dd.length, 1e-6), a + r * math.sin(t) / max(da.length, 1e-6))[0]
                rim.append(bm.verts.new(qq + n * lift))
            for j in range(seg):
                f = bm.faces.new((c, rim[j], rim[(j + 1) % seg]))
                if f.normal.dot(n) < 0:
                    f.normal_flip()
        row += 1
        d += gap * 0.5
    return K.Piece(K._bm_to_mesh(bm, name), SK[pat["dot"]][0], outline=False, smooth=True, name=name)


def _sock_ball(c, r, rot, col, band_col):
    """A rolled-up pair of socks: a squashed ball with the folded-over, ribbed cuff band round it."""
    m = M(c, rot, (1.12, 1.0, 0.86))
    ball = K.sphere(SK[col][0], r, m, seg=10, rings=7, name="sock_ball")
    ball.face_pal = [SK[col][1] if f.normal.z < -0.5 else SK[col][0] for f in ball.mesh.polygons]
    band = K.cylinder(SK[band_col][0], radius=r * 1.06, depth=r * 0.8, mat=m, seg=10, name="sock_band")
    band.face_pal = [SK[band_col][1] if len(f.vertices) > 4 else (SK[band_col][0] if i % 2 else SK[band_col][1])
                     for i, f in enumerate(band.mesh.polygons)]
    return [ball, band]


UP, FRONT = Vector((0, 0, 1)), Vector((0, -1, 0))
HIDDEN = -0.5   # sin(angle round the sock) below this = the side it lies on (dots / argyle skip it)


def _mound(dome, top):
    """The heap's core: a squircle cap filling the mouth whose top IS the dome the socks lie on,
    painted as a big lavender / purple striped sock squashed under all the others (crisp stripes)."""
    bm = bmesh.new()
    rings = []
    hw = _hw(RIM_Z) - 0.02
    for i, r in enumerate((1.0, 0.78, 0.5, 0.24)):
        ring = []
        for j in range(COLS):
            p = _sq(j / COLS)[0] * hw * r
            z = top - 0.6 if i == 0 else dome(p.x, p.y + 0.0, -0.05)
            ring.append(bm.verts.new((p.x, p.y, z)))
        rings.append(ring)
    c = bm.verts.new((0, 0, dome(0, 0, -0.05)))
    for i in range(len(rings) - 1):
        for j in range(COLS):
            k = (j + 1) % COLS
            bm.faces.new((rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]))
    for j in range(COLS):
        bm.faces.new((rings[-1][j], rings[-1][(j + 1) % COLS], c))
    bm.normal_update()
    if sum(f.normal.z for f in bm.faces) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    ca, sa = math.cos(0.5), math.sin(0.5)
    u = {v: (v.co.x * ca + v.co.y * sa) / 0.7 for v in bm.verts}
    _iso_cut(bm, u, [k + 0.5 for k in range(-6, 6)])
    pal = [HEAP[int(math.floor(sum(u[v] for v in f.verts) / len(f.verts) + 0.5)) % 2] for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, "mound"), pal, outline=False, smooth=True, name="mound")


def _lid_z(y):
    """Height of the lid's underside above world y (the plane through the hinge)."""
    return HINGE.z + (HINGE.y - y) * math.tan(LID_OPEN)


def _socks():
    out = []
    top = RIM_Z + RIM_R           # top of the rim
    yf = -(_hw(RIM_Z) + COIL_A * 0.5 + RIM_R)   # front face of the rim
    xe = _hw(RIM_Z) + COIL_A * 0.5 + RIM_R      # side faces of the rim
    t = 0.15
    yo = yf - t - 0.04            # a sock hanging down the front lies here
    # the heap: a core fills the mouth (no gap shows the inside) and domes up under the lid; bunched-up
    # socks lie all over it and two rolled-up pairs sit on top, one propping the lid up
    def dome(x, y, lift=0.0):
        d = 1.3 * max(0.0, 1 - (x / 3.6) ** 2 - ((y + 0.7) / 3.9) ** 2)
        return min(top + 0.1 + d, _lid_z(y) - 0.42) + lift
    out.append(_mound(dome, top))
    # bunched-up socks: short curls on a jittered grid over the mouth, in every sock colour
    rnd = random.Random(5)
    cols = ("teal", "pink", "white", "green", "yellow", "orange", "blue", "purple", "red", "cream")
    k = 0
    for gy in (-2.2, -0.65, 0.9):
        for gx in (-1.9, 0.0, 1.9):
            cx, cy = gx + rnd.uniform(-0.3, 0.3) + (0.5 if gy == -0.65 else -0.2), gy + rnd.uniform(-0.2, 0.2)
            th = rnd.uniform(0, math.tau)
            ca, sa = math.cos(th), math.sin(th)
            pts = [(-0.95, -0.25), (-0.25, 0.3), (0.55, 0.15), (0.9, -0.45)]
            ctrl = []
            for i, (u, v) in enumerate(pts):
                x = max(-2.7, min(2.7, cx + u * ca - v * sa))
                y = max(-2.75, min(2.7, cy + u * sa + v * ca))
                ctrl.append((x, y, dome(x, y, 0.1 + (0.1 if i in (1, 2) else 0.0))))
            col = cols[k % len(cols)]
            acc = cols[(k * 3 + 4) % len(cols)]
            k += 1
            out += _sock(ctrl, [UP] * len(ctrl), dict(kind="plain", body=col, accent=acc), width=0.46,
                         thick=0.16, step=0.45, sides=6, cuff=0.4, toe=0.42, name="bunched")
    out += _sock_ball((-0.95, -1.35, min(dome(-0.95, -1.35, 0.42), _lid_z(-1.35) - 0.56)), 0.6, (0.3, 0.1, 0.5),
                      "yellow", "red")
    zb = _lid_z(0.55) - 0.56 * 0.86 - 0.02
    out += _sock_ball((1.35, 0.55, zb), 0.56, (-0.2, 0.25, -0.6), "white", "blue")
    # 1) red / cream stripes over the front rim, dangling down the front, its foot kicking right
    x = -1.15
    ctrl = [(x + 0.35, -0.9, dome(x + 0.35, -0.9, 0.45)), (x + 0.12, yf + 0.38, top + t + 0.05),
            (x, yo + 0.04, top - 0.3),
            (x - 0.03, yo - 0.02, top - 1.15), (x - 0.02, yo - 0.05, top - 1.85), (x + 0.2, yo - 0.07, top - 2.42),
            (x + 0.85, yo - 0.08, top - 2.6), (x + 1.4, yo - 0.08, top - 2.45)]
    hints = [UP, (0, -0.3, 1), (0, -1, 0.5), FRONT, FRONT, FRONT, FRONT, FRONT]
    out += _sock(ctrl, hints, dict(kind="stripes", body="red", stripe="cream", accent="red", band=0.3), heel=5,
                 name="sock_striped")
    # 2) green polka dots over the left side, hanging down the wall, toe turned to the back
    xs = -xe - t - 0.04
    ctrl = [(-1.6, -0.3, dome(-1.6, -0.3, 0.45)), (xs + 0.38, -0.4, top + t + 0.05), (xs - 0.02, -0.45, top - 0.3),
            (xs - 0.07, -0.5, top - 1.15), (xs - 0.1, -0.45, top - 1.85), (xs - 0.11, -0.1, top - 2.2),
            (xs - 0.11, 0.6, top - 2.2)]
    side = (-1, 0, 0)
    hints = [UP, (-0.3, 0, 1), (-1, 0, 0.5), side, side, side, side]
    out += _sock(ctrl, hints, dict(kind="dots", body="green", dot="yellow", accent="yellow", r=0.11, gap=0.38,
                                   dark_accent=False), heel=4, name="sock_dots")
    # 3) purple argyle flopping out of the gap under the lid, over the front-right rim
    x = 1.3
    ctrl = [(x - 0.2, 0.2, _lid_z(0.2) - 0.25), (x - 0.05, -1.1, dome(x - 0.05, -1.1, 0.45)),
            (x + 0.05, yf + 0.38, top + t + 0.06),
            (x + 0.12, yo + 0.05, top - 0.32), (x + 0.15, yo, top - 1.05), (x + 0.1, yo + 0.02, top - 1.6)]
    hints = [(0, -0.6, 1), UP, (0, -0.3, 1), (0, -1, 0.4), FRONT, FRONT]
    out += _sock(ctrl, hints, dict(kind="argyle", body="purple", diamond="yellow", accent="purple", around=2,
                                   size=0.62), heel=2, name="sock_argyle")
    # 4) blue stripes curled over the left of the heap
    ctrl = [(x, y, dome(x, y, 0.45)) for x, y in ((-2.0, 1.5), (-1.85, 0.3), (-1.0, -0.2), (-0.3, 0.3))]
    hints = [UP, UP, UP, UP]
    out += _sock(ctrl, hints, dict(kind="stripes", body="blue", stripe="white", accent="blue", band=0.28),
                 heel=1, name="sock_blue")
    # 5) pink with white dots over the right of the heap, its foot hanging over the right rim
    xr = xe + t + 0.04
    ctrl = [(0.4, 1.7, dome(0.4, 1.7, 0.45)), (1.5, 1.6, dome(1.5, 1.6, 0.45)), (xr - 0.35, 1.3, top + t + 0.06),
            (xr, 1.2, top - 0.3),
            (xr + 0.06, 1.15, top - 1.1), (xr + 0.08, 1.2, top - 1.75)]
    sideR = (1, 0, 0)
    hints = [UP, UP, (0.3, 0, 1), (1, 0, 0.4), sideR, sideR]
    out += _sock(ctrl, hints, dict(kind="dots", body="pink", dot="white", accent="pink", r=0.085, gap=0.3),
                 heel=2, name="sock_pink")
    # 6) orange sock lying on the floor in front, heel bent, toe pointing back toward the hamper
    z = t + 0.05
    ctrl = [(2.65, -4.25, z), (1.85, -4.3, z), (1.05, -4.2, z), (0.6, -3.95, z), (0.4, -3.4, z)]
    hints = [UP, UP, UP, UP, UP]
    out += _sock(ctrl, hints, dict(kind="stripes", body="orange", stripe="cream", accent="orange", band=0.55),
                 heel=3, name="sock_floor")
    return out


# ---------------------------------------------------------------- build
def build():
    p = _basket()
    p += _lid()
    p += _socks()
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W, outline_only=[_envelope()])
    _no_bounce(outline)
    return [body, outline] + K.markers(NAME)
