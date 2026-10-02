"""
props/basket.py - the Basket prop (ReplicatedStorage.MapMeshes.Basket): the Lint Trap, a giant
round wicker laundry basket overflowing with lint. See props/__init__.py for the conventions every
prop follows.

No concept art shows it, so it is designed to sit in docs/concept/bedroom_keyframe.png: chunky soft
toy shapes, thick ink lines, flat 2-3 tone colours. Woven body: horizontal slats (pillows with a
thin light strip along each slat's top), rows offset by half a slat (over-under weave), a dark
round stake of constant width standing in every seam, the top and bottom rows a darker band; a
fat rolled rim wrapped in broad diagonal binding; a clean dark oval hand hole framed by one plain
band on each side; a darker foot ring.

The lint (no art shows it; modelled on the fluffy cartoon cloud in the painting, props/picture.py):
ONE continuous puffy skin heaped over the rim like a big dust bunny - a dome of round puffs (a ring
resting on the rope, a middle ring, one big crown puff and two smaller ones, a second tier of
small bumps along the cloud edge, fillers in the pits), a continuous roll of overlapping puffs of
uneven size and height curling over the rope's crest, and spilling over it in a cascade of puffs
at the front-left and a smaller tongue at the back-right - in soft lavender-white, cel-shaded lit
/ shade / deep crease, shaded round by normals taken from the field. Three long, thin, loose sock
threads (dusty blue, pink, yellow) lie tangled in it, dipping in and out of the fluff, the pink
one hanging off the big tongue in an open hook; an irregular wad and two small balls of fluff sit
on the floor at the foot of the big tongue. Only the silhouette is inked: an outline-only twin
of the skin, relaxed over its creases (see _membrane) and stripped of the faces that would draw
lines inside the heap (see _cull_inner).
Dimensions in studs (Map.luau fit box 34 x 30 x 34, which the model fills: 33.9 x 33.9 x 29.9),
scaled by S.
"""
import math
import random
import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Basket"
S = 0.1  # model units per stud
INK_W = 0.55  # outline width (studs): about 1.8% of the basket's height, like the art's ink

TAN_L = hexcol("basket_tan_light", "#F2C676")   # thin strip along each slat's top, rope crests
TAN = hexcol("basket_tan", "#D99E4E")           # wicker slats, rope
TAN_M = hexcol("basket_tan_mid", "#A86A30")     # the darker weave bands, slat undersides, rope grooves
TAN_D = hexcol("basket_tan_dark", "#7A4826")    # stakes, foot ring, dark-band undersides
HOLE = hexcol("basket_hole", "#43261A")         # the hand holes
HOLE_RIM = hexcol("basket_hole_rim", "#B97A3A")  # the plain band round each hand hole
FIB_PINK = hexcol("basket_fibre_pink", "#DB869F")   # the sock threads tangled in the lint: dusty
FIB_BLUE = hexcol("basket_fibre_blue", "#7A9FCF")   # sock colours (washed, fluff-coated yarn)
FIB_YELLOW = hexcol("basket_fibre_yellow", "#DDBB5C")


def _ramp(name, hexes):
    """Registers a tone ramp: colours on consecutive swatches of ONE palette row (dark to light),
    so a UV sliding along the row passes through them in order (see _ramp_uvs). If the row would
    break, the ramp is registered again under a suffixed name (the next row then holds it)."""
    for k in range(3):
        idx = [hexcol(f"{name}{'_r%d' % k if k else ''}_{i}", h) for i, h in enumerate(hexes)]
        if idx == list(range(idx[0], idx[0] + len(idx))) and idx[0] % K.GRID + len(idx) <= K.GRID:
            return idx
    raise RuntimeError("no palette row for ramp " + name)


# the lint: soft lavender-white fluff - deep crease / shade (sides, undersides, creases) / lit; the
# end tones are doubled so a blurred (mipmapped) palette never bleeds a neighbour's colour into it
FLUFF = _ramp("basket_fluff", ("#9C99AE", "#9C99AE", "#B9B6C8", "#DCDAE4", "#DCDAE4"))[1:4]
FLUFF_LEVELS = (-0.65, -0.05)  # brightness (see _lint_tone) at the crease/shade and shade/lit edges
AO = (48, 4.0, 0.3, 0.9)  # fluff occlusion: rays, reach (studs), start off the surface (studs), weight
TONE_BLUR = 1.0       # the brightness is blurred over this distance (studs, Gaussian sigma)
THREAD_R = 0.24       # sock thread radius (studs)
THREAD_LIFT = 0.2     # a thread lies this fraction of its radius out of the fluff between dips ...
DIP_DEPTH = 1.6       # ... and at the bottom of each dip this many radii under it (hidden: caught inside)
SAG = 0.2             # it spans a crease at most this far (studs) above the skin under it

# body (studs)
R0, R1 = 12.0, 14.0   # radius at the bottom / top of the woven wall
BELLY = 0.7           # extra radius at mid height (a soft barrel shape)
Z0, Z1 = 1.2, 17.0    # woven wall height
ROWS, CELLS = 4, 10   # weave rows / slats around
DARK_ROWS = (0, ROWS - 1)  # the darker weave bands: bottom and top row
GAP = 0.08            # half width of the seam between two slats (fraction of a slat, ~0.7 studs)
# samples across one slat (the set is the same shifted by half a slat, so odd rows reuse it) and
# up one row (steep shoulders round a flat face: the top shoulder is the thin light strip)
US = (0.0, GAP, 0.5 - GAP, 0.5, 0.5 + GAP, 1.0 - GAP)
VS = (0.0, 0.15, 0.85)
BULGE = 1.1           # slat height above the seam floor
STAKE = 0.4           # the round stake standing in each seam
RIM_Z, RIM_R, RIM_C = 18.2, 2.3, R1 + 0.7  # rolled rim: height, tube radius, centre-line radius
HOLE_Z, HOLE_A, HOLE_B = 12.4, 4.4, 2.5    # hand hole: centre height, oval half width / half height
HOLE_W, HOLE_T, HOLE_SEG = 0.65, 0.22, 6   # its band: half width on the wall, half thickness, segments


def _mesh(name, verts, faces, fix=False):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v * S) for v in verts], [], faces)
    me.update()
    if fix:  # closed solids built by hand: let bmesh point every face outward
        bm = bmesh.new()
        bm.from_mesh(me)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm.to_mesh(me)
        bm.free()
        me.update()
    return me


def _radius(z):
    t = (z - Z0) / (Z1 - Z0)
    return R0 + (R1 - R0) * t + BELLY * math.sin(math.pi * min(max(t, 0.0), 1.0))


def _on_wall(t, z, side, lift):
    """A point `t` studs along the wall (around the basket) from the +X (side 1) or -X (side -1)
    axis at height z, `lift` studs out from the slats' outer faces."""
    rho = _radius(z) + BULGE + lift
    ang = t / rho + (0.0 if side > 0 else math.pi)
    return Vector((math.cos(ang) * rho, math.sin(ang) * rho, z))


def _seam_dist(lu, row):
    """Distance (in slats) from the nearest seam of `row` (odd rows are shifted half a slat)."""
    d = (lu + 0.5 * (row % 2)) % 1.0
    return min(d, 1.0 - d)


def _weave():
    """Lathe of flat-faced slats: each row's slats stand BULGE proud of a flat seam floor, odd rows
    shifted half a slat (over-under weave), a round stake standing in every seam (constant width,
    square ends where the next row's slat covers it). Colours: the band colour on the slat face, a
    thin light strip on its top shoulder, shade underneath, dark stakes in the seams."""
    nu, nv = CELLS * len(US), ROWS * len(VS)
    verts, faces = [], []
    for iv in range(nv + 1):
        row, k = divmod(iv, len(VS))
        z = Z0 + (Z1 - Z0) * (row + (VS[k] if row < ROWS else 0.0)) / ROWS
        for iu in range(nu):
            cell, j = divmod(iu, len(US))
            lu = US[j]
            if k == 0:  # row boundary, shared by two rows: only the stakes (of either row) stand out
                off = STAKE if lu in (0.0, 0.5) else 0.0
            else:
                d = _seam_dist(lu, row)
                off = STAKE if d < 1e-6 else (0.0 if d < GAP + 1e-6 else BULGE)
            a = (cell + lu) / CELLS * math.tau
            r = _radius(z) + off
            verts.append(Vector((math.cos(a) * r, math.sin(a) * r, z)))
    cols = []
    for iv in range(nv):
        row, k = divmod(iv, len(VS))
        dark = row in DARK_ROWS
        for iu in range(nu):
            a, b = iv * nu + iu, iv * nu + (iu + 1) % nu
            faces.append((a, b, b + nu, a + nu))
            l0, l1 = US[iu % len(US)], US[(iu + 1) % len(US)]
            if _seam_dist(l0, row) < GAP + 1e-6 and _seam_dist(l1, row) < GAP + 1e-6:
                cols.append(TAN_D)                       # the stake in the seam
            elif k == len(VS) - 1:
                cols.append(TAN_L)                       # thin light strip along the slat's top
            elif k == 0:
                cols.append(TAN_D if dark else TAN_M)    # shaded underside
            else:
                cols.append(TAN_M if dark else TAN)      # slat face: the band colour
    return K.Piece(_mesh("weave", verts, faces), cols, outline=False, smooth=True, name="weave")


def _weave_ink():
    """Outline-only envelope round the slats' outer faces (closed, smooth): the woven wall gets
    one clean silhouette line instead of the hull poking dark streaks into every seam."""
    nu, nv = 32, 6
    verts, faces = [], []
    for iv in range(nv + 1):
        z = Z0 + (Z1 + 0.4 - Z0) * iv / nv
        r = _radius(min(z, Z1)) + BULGE * 0.95
        for iu in range(nu):
            a = iu / nu * math.tau
            verts.append(Vector((math.cos(a) * r, math.sin(a) * r, z)))
    for iv in range(nv):
        for iu in range(nu):
            a, b = iv * nu + iu, iv * nu + (iu + 1) % nu
            faces.append((a, b, b + nu, a + nu))
    faces.append(tuple(range(nu))[::-1])
    faces.append(tuple(range(nv * nu, (nv + 1) * nu)))
    return K.Piece(_mesh("weave_ink", verts, faces, fix=True), K.OUTLINE, outline=True, smooth=True, name="weave_ink")


def _frames(pts):
    """Parallel-transport frames (normal, binormal) along the closed loop `pts`."""
    n, out, nv = len(pts), [], None
    for i in range(n):
        t = (pts[(i + 1) % n] - pts[i - 1]).normalized()
        nv = t.orthogonal().normalized() if nv is None else (nv - t * nv.dot(t)).normalized()
        out.append((nv, t.cross(nv)))
    return out


def _tube_faces(n, mseg, shift=0):
    """Quads of a closed tube: n rings of mseg verts; the last ring joins the first `shift` on."""
    faces = []
    for i in range(n):
        i2, sh = (i + 1) % n, (shift if i == n - 1 else 0)
        for j in range(mseg):
            faces.append((i * mseg + j, i2 * mseg + (j + sh) % mseg, i2 * mseg + (j + 1 + sh) % mseg, i * mseg + (j + 1) % mseg))
    return faces


def _rope_loop(name, pts, minor, twists, pattern, mseg):
    """A closed wrapped rope through the loop `pts` (studs). Each ring of the tube is turned a
    little further round (`twists` turns over the loop) and the mesh's own strips run as
    helices: every ply (`pattern` = its faces' colours) is one broad diagonal wrap - clean
    continuous binding, no stair-steps. When each ring turns by exactly one face, every ring has
    the same cross-section (a perfectly smooth silhouette) and each sheared quad is split along
    its axial diagonal. The rope draws no outline of its own: see _rim_ink."""
    n, P = len(pts), len(pattern)
    assert mseg % P == 0 and abs(twists * mseg - round(twists * mseg)) < 1e-6
    shift = round(twists * mseg) % mseg
    assert shift % P == 0
    verts, pal = [], []
    for i, (c, (nv, bv)) in enumerate(zip(pts, _frames(pts))):
        rot = twists * math.tau * i / n
        for j in range(mseg):
            b = math.tau * j / mseg + rot
            verts.append(c + (nv * math.cos(b) + bv * math.sin(b)) * minor)
    faces = _tube_faces(n, mseg, shift)
    pal = [pattern[(k % mseg) % P] for k in range(len(faces))]
    if abs(twists * mseg - n) < 1e-6:  # one face per ring: (a, b, c, d) -> (a, b, d) + (b, c, d)
        faces = [t for a, b, c, d in faces for t in ((a, b, d), (b, c, d))]
        pal = [c for c in pal for _ in (0, 1)]
    return K.Piece(_mesh(name, verts, faces, fix=True), pal, outline=False, smooth=True, name=name)


def _rim():
    def ring(n):
        return [Vector((math.cos(math.tau * i / n) * RIM_C, math.sin(math.tau * i / n) * RIM_C, RIM_Z)) for i in range(n)]
    rope = _rope_loop("rim", ring(48), RIM_R, twists=4, pattern=(TAN, TAN_L, TAN_L, TAN, TAN, TAN_M), mseg=12)
    return rope, _rim_ink()


# cross-section of the rim's ink tube: (angle round the rope in degrees, 0 = outward, 90 = up;
# radius / RIM_R). Full size (the hull then shows ~0.6 studs outside the rope) on the outside and
# the outer underside, which is the rope's silhouette from every view. Elsewhere it sits inside
# the rope (radius + outline <= RIM_R): straight under the rope a full hull would show as dark
# teeth in the recessed seams of the top weave row, and over the top and the inner side, where
# the lint rests on the rope, it could only draw broken dashes wherever a gap opens in the lint
# behind it - the strong tan/grey colour change marks that edge instead.
RIM_INK = ((-90, 0.76), (-75, 0.9), (-55, 1.04), (-20, 1.04), (15, 1.04), (40, 1.0), (58, 0.74),
           (90, 0.6), (170, 0.6), (230, 0.7))


def _rim_ink(n=48):
    """Outline-only tube round the rim rope (see RIM_INK): a full tube's hull would poke through
    the lint resting on the rope's inner top as dark scratches; the colour change (and the lint's
    own skin) marks that edge instead."""
    verts = []
    for i in range(n):
        a = math.tau * i / n
        out, c = Vector((math.cos(a), math.sin(a), 0.0)), Vector((math.cos(a) * RIM_C, math.sin(a) * RIM_C, RIM_Z))
        for deg, k in RIM_INK:
            b = math.radians(deg)
            verts.append(c + (out * math.cos(b) + Vector((0, 0, 1)) * math.sin(b)) * RIM_R * k)
    me = _mesh("rim_ink", verts, _tube_faces(n, len(RIM_INK)), fix=True)
    return K.Piece(me, K.OUTLINE, outline=True, smooth=True, name="rim_ink")




def _handle(side):
    """A hand hole just under the rim: a clean dark oval, framed by one smooth flat band, both lying
    on the wall (following its curve); `side` +1 / -1 = +X / -X. The band is a flattened tube in one
    colour (no twist, no highlight stripes - a puffy striped rope there read as a pair of lips); its
    ink comes from its own hull, which draws a line round its outer edge and one round the hole."""
    n = 20
    ring = [(math.cos(math.tau * k / n) * HOLE_A, math.sin(math.tau * k / n) * HOLE_B) for k in range(n)]
    verts = []
    for k, (x, y) in enumerate(ring):
        # in-plane outward direction of the oval at this point (its 2D normal)
        nx, ny = x / HOLE_A ** 2, y / HOLE_B ** 2
        ln = math.hypot(nx, ny)
        nx, ny = nx / ln, ny / ln
        for j in range(HOLE_SEG):
            b = math.tau * j / HOLE_SEG
            dx, dy = nx * math.cos(b) * HOLE_W, ny * math.cos(b) * HOLE_W
            verts.append(_on_wall(x + dx, HOLE_Z + y + dy, side, 0.15 + HOLE_T * (1.0 + math.sin(b))))
    faces = _tube_faces(n, HOLE_SEG)
    band = K.Piece(_mesh("hole_band", verts, faces, fix=True), HOLE_RIM, outline=True, smooth=True, name="hole_band")
    # the dark opening: an oval sheet just proud of the slats, tucked under the band all round
    a, b = HOLE_A - HOLE_W * 0.4, HOLE_B - HOLE_W * 0.4
    nu, nv = 6, 4
    verts, faces = [], []
    for iv in range(nv + 1):
        v = -1.0 + 2.0 * iv / nv
        w = a * math.sqrt(max(0.0, 1.0 - v * v))
        for iu in range(nu + 1):
            verts.append(_on_wall(-w + 2 * w * iu / nu, HOLE_Z + b * v, side, 0.12))
    for iv in range(nv):
        for iu in range(nu):
            k = iv * (nu + 1) + iu
            faces.append((k, k + 1, k + nu + 2, k + nu + 1))  # faces outward on both sides
    slot = K.Piece(_mesh("hole", verts, faces), HOLE, outline=False, smooth=True, name="hole")
    return [slot, band]


# ---------------------------------------------------------------- the lint heap
# One soft continuous skin: a metaball cloud of round puffs (the shape of the art's cartoon cloud:
# rounded bumps all along the silhouette, softly melted together in the creases), polygonised
# finely, decimated to the budget (sparing the silhouette regions: the rim, the tongues, the crown)
# and relaxed back onto the field's surface.
# Its ink comes from an outline-only TWIN: a coarser copy of the same skin, relaxed into a membrane
# (_membrane) that hugs every bump of the side silhouettes (an even line round each puff) and
# spans the creases on the dome's top and between the puffs round the rim (_ink_bounds); then the
# faces whose hull would mostly draw a line over the fluff rather than round it - where one puff
# stands in front of another, seen from the game's camera all round - are dropped (_cull_inner).
# Where the lint rests on the rope the twin sinks under the skin: no broken dashes on the rope.
# The cel tones come from the field (smooth whatever the mesh), blurred in 3D and painted with a UV
# ramp (see _ramp_uvs). Ball radii are the VISIBLE radius of a lone ball (studs).
MB_T, MB_S = 0.6, 8.0  # metaball threshold and stiffness (stiffer = rounder, more separate puffs)
INK_FIT = 0.05         # how far (studs) the twin stands out of the skin over the top of each puff
INK_FILL = 1.6         # ... and at most in the creases it spans on the dome's top (see _membrane) ...
INK_SIDE = 0.4         # ... between the puffs round the rim (where the skin faces sideways or in) ...
INK_EDGE = 0.15        # ... where it faces straight out and on the tongues, the side silhouettes:
                       # there it follows every bump, so the line keeps an even width
INK_SINK = -0.8        # ... and where the lint rests on the rope: under the skin (see _ink_bounds)
MB_RES = 0.4           # polygonisation cell (studs) before decimation
HEAP_TRIS = 4250       # triangle budgets after decimation: the heap ...
FLOOR_TRIS = 470       # ... the dust bunny on the floor ...
INK_TRIS = 4350        # ... the heap's outline twin (before the faces near the rope are dropped) ...
FLOOR_INK_TRIS = 450   # ... and the dust bunny's
INK_VIEWS = ((-10, 0.3), (5, 1.0), (20, 1.0), (35, 0.6), (50, 0.15), (70, 0.05))  # (elevation, weight)
CULL = 1.0             # the twin's faces drawing this many times more inner lines than outline go
INK_GAP = 2.0          # an inner line counts in full where the fluff behind it is this far back (studs)
KEEP, KEEP_F = 0.9, 0.6  # decimation: how much the silhouette regions are spared (see _keep)
PIVOT = (0.0, 0.0, 18.5)  # the heap's centre (studs): bumps are placed on rays from it
TONGUES = (-135.0, 45.0)  # where the two tongues spill over the rim (degrees)


def _mb_radius(r, s=MB_S):
    """Element radius whose lone ball (stiffness s) shows a surface of radius `r` (field
    s*(1-d^2/R^2)^3 = t)."""
    return r / math.sqrt(1.0 - (MB_T / s) ** (1.0 / 3.0))


def _polar(ang, rho, z, r):
    a = math.radians(ang)
    return (math.cos(a) * rho, math.sin(a) * rho, z, r)


def _field(balls, s=MB_S):
    """The metaball field F (positive inside) and its gradient, for points P (N x 3, studs)."""
    C = np.array([b[:3] for b in balls], dtype=float)
    R2 = np.array([_mb_radius(b[3], s) ** 2 for b in balls])

    def field(P):
        P = np.asarray(P, dtype=float).reshape(-1, 3)
        f, g = np.empty(len(P)), np.empty((len(P), 3))
        for k in range(0, len(P), 2048):
            D = P[k:k + 2048, None, :] - C[None, :, :]
            u = np.clip(1.0 - (D * D).sum(-1) / R2, 0.0, None)
            f[k:k + 2048] = s * (u ** 3).sum(1) - MB_T
            g[k:k + 2048] = (s * 3.0 * (u ** 2)[..., None] * (-2.0 * D / R2[None, :, None])).sum(1)
        return f, g
    return field


def _on_skin(balls, specs):
    """Small bumps sitting on the skin of `balls`: for each (azimuth, elevation (degrees, a ray from
    PIVOT), radius, protrusion as a fraction of the radius) a ball whose centre lies that deep
    under the surface where the ray leaves the skin."""
    field = _field(balls)
    out = []
    for az, el, r, pro in specs:
        a, e = math.radians(az), math.radians(el)
        d = np.array((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e)))
        ts = np.arange(30.0, 0.0, -0.05)
        f, _ = field(np.array(PIVOT)[None, :] + ts[:, None] * d[None, :])
        t = ts[int(np.argmax(f > 0))]  # the last exit from the skin, walking in from outside
        p = np.array(PIVOT) + d * t
        _, g = field(p[None, :])
        n = -g[0] / max(np.linalg.norm(g[0]), 1e-9)
        c = p - n * r * (1.0 - pro)
        out.append((c[0], c[1], c[2], r))
    return out


def _pit_fillers(balls, most=12):
    """Small filler balls for the deepest pits between the top puffs (seen from above they read
    as dark holes in a sponge): the skin's distance from PIVOT is sampled over the upper dome; where
    it falls short of the average a ring of neighbours 10 degrees round reaches, by more than 0.5
    studs, a ball of radius 1.2-1.8 is sunk into the pit."""
    field = _field(balls)
    D, A = [], []
    for el in range(12, 88, 3):
        for az in range(0, 360, max(3, int(round(3 / math.cos(math.radians(el)))))):
            a, e = math.radians(az), math.radians(el)
            D.append((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e)))
    D = np.array(D)
    ts = np.arange(16.0, 4.0, -0.1)
    f, _ = field((np.array(PIVOT)[None, None, :] + ts[None, :, None] * D[:, None, :]).reshape(-1, 3))
    inside = f.reshape(len(D), len(ts)) > 0
    r = ts[np.argmax(inside, axis=1)]
    cosang = D @ D.T
    ring = (cosang < math.cos(math.radians(7))) & (cosang > math.cos(math.radians(13)))
    depth = np.array([r[ring[i]].mean() - r[i] if ring[i].any() else 0.0 for i in range(len(D))])
    near = cosang > math.cos(math.radians(12))
    out = []
    for i in np.argsort(-depth):
        if depth[i] < 0.5 or len(out) >= most:
            break
        if any(near[i, k] for k, _ in out):
            continue
        rf = min(max(1.0 + depth[i] * 0.6, 1.2), 1.8)
        c = np.array(PIVOT) + D[i] * (r[i] + 0.15 * rf)
        out.append((i, (c[0], c[1], c[2], rf)))
    return [b for _, b in out]


def _tongue(ang, puffs):
    """A tongue of fluff spilling over the rim at `ang` degrees: puffs (u = out from the axis, z,
    radius, v = sideways) cascading over the rope and down the wall."""
    a = math.radians(ang)
    out, tan = Vector((math.cos(a), math.sin(a), 0)), Vector((-math.sin(a), math.cos(a), 0))
    return [tuple(out * u + tan * v)[:2] + (z, r) for u, z, r, v in puffs]


def _heap_balls():
    """-> ([(x, y, z, r)] studs, [True for the hidden core balls]): the heap in the basket, its
    bumpy cloud edge, the puffs bulging over the rope and the two tongues."""
    rnd = random.Random(7)
    j = rnd.uniform
    # the hidden core that fills the basket mouth (so no gap ever shows the inside)
    core = [(0.0, 0.0, 19.2, 6.0)] + [_polar(k * 60 + 15, 7.4, 18.8, 5.0) for k in range(6)]
    balls = []
    # the dome: a ring of puffs resting on the rope's inner half, a middle ring, and a crown - one
    # big puff a little off centre and two smaller ones
    ring_r = (3.5, 2.8, 3.3, 3.0, 3.7, 2.7, 3.2, 3.5, 2.9, 3.4, 3.0, 2.7, 3.3)
    for k, r in enumerate(ring_r):
        balls.append(_polar(k * 360 / len(ring_r) + 8 + j(-5, 5), 11.9 + j(-0.3, 0.4) - 0.25 * (r - 3.1),
                            21.3 + j(-0.2, 0.4) + 0.3 * (r - 3.1), r))
    mid_r = (3.9, 3.5, 4.1, 3.6, 3.8, 3.4, 4.0)
    for k, r in enumerate(mid_r):
        balls.append(_polar(k * 360 / len(mid_r) + 22 + j(-6, 6), 7.9 + j(-0.4, 0.4), 24.0 + j(-0.3, 0.3) + 0.4 * (r - 3.7), r))
    balls.append((-1.0, 0.9, 24.9, 5.0))     # the crown
    balls.append(_polar(-62, 5.2, 25.8, 3.1))
    balls.append(_polar(118, 5.6, 25.6, 3.2))
    # round puffs bulging over the rope at nine uneven spots between the tongues (2-2.8 studs, at
    # uneven heights): each curls over the rope's crest and partway down its outer side, so the
    # lint's lower edge wanders up and down over the rope and every puff gets its own crescent of
    # shade (sizes kept inside the fit box, which is tightest along the axes)
    for ang, rho, z, r in ((-103, 14.8, 20.9, 2.3), (-73, 15.0, 20.3, 2.7), (-41, 15.3, 21.4, 2.2),
                           (-10, 14.6, 20.5, 2.1), (18, 14.9, 21.3, 2.5), (79, 14.7, 20.4, 2.5),
                           (110, 15.0, 21.4, 2.2), (146, 15.4, 20.2, 2.8), (176, 14.5, 21.0, 2.0)):
        balls.append(_polar(ang + j(-2, 2), rho, z, r))
    # ... and a smaller puff a little further in and up in each valley between two of them, so the
    # band round the rim is one continuous roll of overlapping scallops (no deep valley that would
    # show one puff's outline standing in front of the next)
    for ang, rho, z, r in ((-88, 14.0, 21.6, 1.9), (-57, 14.2, 21.0, 1.8), (-25, 14.0, 21.5, 1.9), (4, 14.2, 21.0, 1.8),
                           (31, 14.0, 21.6, 1.7), (62, 14.0, 21.5, 1.8), (95, 14.1, 21.5, 1.9), (128, 14.3, 21.2, 2.0),
                           (161, 14.1, 21.6, 1.9), (192, 14.3, 21.2, 1.9), (207, 14.0, 21.5, 1.7), (241, 14.1, 21.4, 1.8)):
        balls.append(_polar(ang, rho, z, r))
    # the big tongue at the front-left: a cascade growing out from under the dome's edge - a fat
    # upper lobe with bumpy shoulders at different heights, the lower body leaning to one side and
    # one small drip hanging clearly lowest (a drip of fluff, nothing symmetric)
    balls += _tongue(TONGUES[0], [(14.9, 21.0, 3.1, -0.4), (15.9, 20.4, 2.2, 2.8), (16.3, 18.6, 1.7, -3.1),
                                  (17.3, 17.4, 2.4, 0.5), (17.6, 15.8, 1.7, -0.9), (17.9, 13.6, 1.25, 1.2),
                                  (17.0, 16.9, 1.1, 2.5), (18.5, 18.6, 1.2, -1.1)])
    # the smaller one at the back-right
    balls += _tongue(TONGUES[1], [(14.0, 22.4, 3.0, -2.6), (14.0, 22.4, 3.0, 2.4),
                                  (16.9, 19.6, 2.5, -2.0), (16.9, 20.0, 2.5, 2.2),
                                  (17.1, 16.9, 1.8, -1.2), (17.1, 17.4, 1.8, 1.6)])
    # a second tier of small bumps over the outer and middle rings (more, smaller bumps along every
    # silhouette), and fillers in the pits between the top puffs
    tier = [(k * 45 + 21 + j(-8, 8), 21 + j(-3, 4), j(1.2, 1.7), 0.5) for k in range(8)]
    tier += [(k * 90 + 50 + j(-10, 10), 44 + j(-4, 4), j(1.4, 1.8), 0.5) for k in range(4)]
    balls += _on_skin(core + balls, tier)
    balls += _pit_fillers(core + balls)
    return core + balls, [True] * len(core) + [False] * len(balls)


def _floor_balls():
    """-> [(x, y, z, r)] studs: a loose wad of fluff on the floor at the foot of the big tongue - an
    irregular, slightly elongated clump of uneven bumps, squashed flat where it sits (the mesh is
    flattened at the floor, see _lint), higher at one end - and two small loose fluff balls along
    the basket's foot, a stud or two off."""
    a = math.radians(-140)
    out, tan = Vector((math.cos(a), math.sin(a), 0)), Vector((-math.sin(a), math.cos(a), 0))
    c = out * 18.0
    balls = []
    for o, t, z, r in ((0.3, -1.4, 1.15, 1.65), (-0.4, 0.5, 0.75, 1.3), (0.5, 1.6, 0.45, 0.95),
                       (-0.2, 2.6, 0.3, 0.75), (0.7, -1.9, 2.1, 0.9), (-0.6, -0.4, 1.6, 0.8)):
        p = c + out * o + tan * t
        balls.append((p.x, p.y, z, r))
    for ang, rho, r in ((-124.0, 16.3, 1.0), (-157.0, 16.8, 0.85)):  # the loose balls
        b = math.radians(ang)
        balls.append((math.cos(b) * rho, math.sin(b) * rho, r * 0.7, r))
    return balls


def _in_basket(p):
    """True for a point (studs) hidden inside the basket: below the rope's crest inside the wall,
    or inside the rope."""
    rho = math.hypot(p.x, p.y)
    return (p.z < RIM_Z + 0.3 and rho < _radius(min(p.z, Z1)) + 0.3) or math.hypot(rho - RIM_C, p.z - RIM_Z) < RIM_R - 0.1


def _ramp01(a, b, x):
    """0 at x = a, 1 at x = b, linear between (a > b counts down)."""
    return min(max((x - a) / (b - a), 0.0), 1.0)


def _rope_dist(p):
    """Distance (studs) from a point to the rim rope's surface (negative inside it)."""
    return math.hypot(math.hypot(p[0], p[1]) - RIM_C, p[2] - RIM_Z) - RIM_R


def _tongue_dist(p):
    """Angle (degrees) from a point (studs) to the nearer tongue's azimuth."""
    az = math.degrees(math.atan2(p[1], p[0]))
    return min(abs((az - ang + 180.0) % 360.0 - 180.0) for ang in TONGUES)


def _sink(p, n):
    """0..1: how far the outline twin sinks under the skin at point p (studs) whose skin normal
    there is n, see _ink_bounds: 1 where the fluff rests on the rope (within 0.6 studs of it and
    facing it), 0 more than 1.4 studs away or where the skin faces away from the rope (a puff's
    outer face, the sides of a tongue hanging past it: silhouettes that keep their line)."""
    rho = math.hypot(p[0], p[1])
    c = np.array((p[0] * RIM_C / max(rho, 1e-9), p[1] * RIM_C / max(rho, 1e-9), RIM_Z))  # rope centre-line
    to = c - np.asarray(p, dtype=float)
    facing = float(np.dot(n, to)) / max(float(np.linalg.norm(to)), 1e-9)
    t = _ramp01(1.4, 0.6, _rope_dist(p)) * _ramp01(0.05, 0.45, facing)
    # ... and on the top of each tongue where it faces up and back toward the dome: seen from the
    # players' eye line its outline would cross the dome behind (the tongue grows out of the heap);
    # the faces turned outward keep their line (the tongue's silhouette seen from the side)
    out = (n[0] * p[0] + n[1] * p[1]) / max(rho, 1e-9)
    return max(t, _ramp01(26.0, 18.0, _tongue_dist(p)) * _ramp01(13.6, 14.8, rho) * _ramp01(19.6, 21.0, p[2])
               * _ramp01(0.3, 0.6, float(n[2])) * _ramp01(0.15, -0.15, out))


def _ink_bounds(p, n, m=None):
    """(lo, hi): how far (studs) the outline twin may stand out of the skin at point p, where the
    skin's normal is n (see _membrane). Over the top of every puff it rests INK_FIT out. Where the
    skin faces up (the creases between the dome's puffs, seen from the side) it may span creases up
    to INK_FILL deep, and between the puffs round the rim (where the skin turns sideways or in,
    toward a neighbour or the dome) up to INK_SIDE: no line where one puff stands in front of
    another. Where it faces straight out (the side silhouettes) and on the tongues hanging over the
    rim only INK_EDGE: the line follows every bump at an even width instead of filling the notches
    with a fat black band. Where the lint rests on the rope the twin sinks under the skin (and those
    faces are then dropped, see _membrane): the strong white/tan colour change marks that edge (a
    hull there drew broken scratches on the rope). It also sinks over the top of each tongue where
    the skin faces up and back toward the dome, so seen from the eye line the tongue's upper edge
    draws no line across the dome behind it: the tongue grows out of the heap."""
    t = _sink(p, n)
    rho = max(math.hypot(p[0], p[1]), 1e-9)
    up = max(_ramp01(0.2, 0.6, n[2]), _ramp01(10.5, 8.5, rho))
    out = (n[0] * p[0] + n[1] * p[1]) / rho
    side = abs(n[1] * p[0] - n[0] * p[1]) / rho
    turn = _ramp01(15.0, 45.0, math.degrees(math.atan2(side, out))) * _ramp01(0.1, 0.3, math.hypot(n[0], n[1]))
    tongue = _ramp01(30.0, 22.0, _tongue_dist(p)) * _ramp01(13.5, 15.0, rho) * _ramp01(21.5, 20.5, p[2])
    fill = INK_EDGE + (INK_SIDE - INK_EDGE) * turn
    fill = (fill + (INK_FILL - fill) * up) * (1.0 - tongue) + INK_EDGE * tongue
    lo = INK_FIT + (INK_SINK - INK_FIT) * t
    return lo, max(lo, fill * (1.0 - t) + INK_SINK * t)


def _keep(p):
    """How much the decimation spares a point (studs), 0..1: the silhouette regions - the outer
    band, the drips and tongues, the crown - keep their triangles; the hidden middle gives them up."""
    rho = math.hypot(p.x, p.y)
    return max(min(max((rho - 8.5) / 3.0, 0.0), 1.0), min(max((p.z - 26.0) / 2.0, 0.0), 1.0), 0.2)


def _polygonise(balls, res, s=MB_S):
    """The balls (studs) as one Blender metaball, converted to a mesh (model units)."""
    mb = bpy.data.metaballs.new("BasketLintMB")
    mb.resolution = mb.render_resolution = res * S
    mb.threshold = MB_T
    for x, y, z, r in balls:
        e = mb.elements.new()
        e.co = (x * S, y * S, z * S)
        e.radius = _mb_radius(r, s) * S
        e.stiffness = s
    ob = K.link(bpy.data.objects.new("BasketLintMB", mb))
    bpy.context.view_layer.update()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    bpy.data.objects.remove(ob)
    bpy.data.metaballs.remove(mb)
    return me


def _metaballs(balls, tris_max, res, hidden=None, s=MB_S):
    """Polygonises the balls (studs) into one mesh (model units), decimated to `tris_max` (sparing
    the silhouette regions, see _keep), then relaxed: every vertex slides toward its neighbours'
    average and is snapped back onto the field's surface, which evens out the decimation's slivers."""
    me = _polygonise(balls, res, s)
    if hidden is not None:  # faces out of sight (inside the basket): no budget wasted on them
        bm = bmesh.new()
        bm.from_mesh(me)
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if all(hidden(v.co / S) for v in f.verts)], context="FACES")
        bm.to_mesh(me)
        bm.free()
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    obj = K.link(bpy.data.objects.new("lint", me))
    if tris > tris_max:
        vg = obj.vertex_groups.new(name="keep")  # low weight = collapsed reluctantly
        for v in me.vertices:
            vg.add([v.index], 1.0 - KEEP * _keep(v.co / S), "REPLACE")
        mod = obj.modifiers.new("dec", "DECIMATE")
        mod.ratio = tris_max / tris
        mod.use_collapse_triangulate = True
        mod.vertex_group = "keep"
        mod.vertex_group_factor = KEEP_F
    me = K.bake_object(obj)
    field = _field(balls, s)
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    bm.verts.index_update()
    nbr = [[] if v.is_boundary else [e.other_vert(v).index for e in v.link_edges] for v in bm.verts]
    tri = np.array([[v.index for v in f.verts[:3]] for f in bm.faces])

    def folded(P):
        """Vertices of faces that turned away from the field's surface normal (a fold would show
        as a see-through slit: the game culls back faces)."""
        a, b, c = P[tri[:, 0]], P[tri[:, 1]], P[tri[:, 2]]
        fn = np.cross(b - a, c - a)
        _, g = field((a + b + c) / 3.0)
        bad = (fn * -g).sum(1) <= 0.25 * np.linalg.norm(fn, axis=1) * np.linalg.norm(g, axis=1)
        return np.unique(tri[bad])

    def snap(P):
        for _ in range(3):  # Newton steps back onto F = 0
            f, g = field(P)
            P = P - (f / np.maximum((g * g).sum(1), 1e-9))[:, None] * g
        return P

    P = snap(np.array([v.co for v in bm.verts]) / S)
    for _ in range(8):
        avg = np.array([P[nb].mean(0) if nb else P[i] for i, nb in enumerate(nbr)])
        f, g = field(P)
        n = -g / np.maximum(np.linalg.norm(g, axis=1), 1e-9)[:, None]
        d = avg - P
        Q = snap(P + 0.6 * (d - n * (d * n).sum(1)[:, None]))
        for _ in range(4):  # moves that fold a face are undone
            bad = folded(Q)
            if not len(bad):
                break
            Q[bad] = P[bad]
        P = Q
    for v, p in zip(bm.verts, P):
        v.co = Vector(p * S)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    me.update()
    return me


def _cull_inner(twin, lint, solids, width):
    """Drops the outline twin's faces (`twin`, model units) whose hull would mostly draw lines INSIDE
    the heap rather than round it: from views all round (INK_VIEWS: the game's camera, mostly a
    little above), each face's hull (`width` model units out) is checked where it would show - its
    face turned away from the camera and nothing of the body (`lint` + `solids`, meshes) in front of
    it - and what lies behind it there: fluff (a line where one puff stands in front of another:
    the long double lines round the shoulders, the hooks and slivers in the creases) or not (the
    background or the basket: a silhouette). A face whose inner lines outweigh its silhouette lines
    CULL times is dropped; the skin right in front of it hides the gap."""
    fluff, body = _bvh(lint), _bvh(lint + solids)
    dirs = []
    for el, w in INK_VIEWS:
        for az in range(0, 360, 10):
            a, e = math.radians(az + 5.0 * (el % 2)), math.radians(el)
            dirs.append((Vector((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e))), w))
    eps = 0.02 * S
    bm = bmesh.new()
    bm.from_mesh(twin)
    bm.normal_update()
    bm.faces.ensure_lookup_table()
    votes = np.zeros((len(bm.faces), 2))  # (inner, silhouette)
    for f in bm.faces:
        n, c = f.normal, f.calc_center_median()
        h = c + n * width
        for d, w in dirs:
            if n.dot(d) > -0.05 or body.ray_cast(h + d * eps, d)[0] is not None:
                continue  # the hull is not seen from there
            hf, hb = fluff.ray_cast(h - d * eps, -d), body.ray_cast(h - d * eps, -d)
            if hb[0] is None:  # nothing behind: a silhouette
                votes[f.index, 1] += w
            else:  # something behind: the further back it is, the longer the line drawn over it
                votes[f.index, 0 if hf[0] is not None and hf[3] <= hb[3] + 1e-6 else 1] += w * min(hb[3] / (INK_GAP * S), 1.0)
    # pooled over each face's neighbours, so whole stretches go or stay, not dashes
    nbr = [list({g.index for v in f.verts for g in v.link_faces}) for f in bm.faces]
    votes = np.array([votes[nb].sum(0) / len(nb) for nb in nbr])
    cut = votes[:, 0] > CULL * votes[:, 1]
    for _ in range(3):  # then each face follows the majority of its neighbours: no lone dashes
        cut = np.array([cut[nb].mean() > 0.5 if abs(cut[nb].mean() - 0.5) > 0.01 else cut[i] for i, nb in enumerate(nbr)])
    dead = [f for f in bm.faces if cut[f.index]]
    bmesh.ops.delete(bm, geom=dead, context="FACES")
    bm.to_mesh(twin)
    bm.free()
    twin.update()
    return twin


def _membrane(me, skin, bounds, iters=250, drop_sunk=False):
    """Relaxes the outline twin `me` (model units) into a membrane stretched over the skin (a mesh
    in model units): smoothed again and again, but at every point p never nearer the skin than lo
    nor further out than hi (studs; `bounds(p, skin normal, membrane normal)` -> (lo, hi), see
    _ink_bounds). It rests on the top
    of every puff and spans the creases between them, so its hull draws the silhouette - a line
    round each bump - but no line where one puff stands in front of another, and no hairline
    scratches in the creases. With drop_sunk, every face with a corner pushed under the skin (lo < 0)
    is dropped: hidden anyway, and its slope is what poked thin slivers through the skin."""
    bvh = BVHTree.FromPolygons([v.co for v in skin.vertices], [tuple(p.vertices) for p in skin.polygons])
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.index_update()
    nbr = [[e.other_vert(v).index for e in v.link_edges] for v in bm.verts]
    free = np.array([not v.is_boundary for v in bm.verts])
    P = np.array([v.co for v in bm.verts]) / S
    # the umbrella operator: lap(X) = mean of the neighbours - X
    rows = np.repeat(np.arange(len(nbr)), [len(nb) for nb in nbr])
    cols = np.concatenate([nb for nb in nbr if nb]).astype(int)
    deg = np.maximum(np.array([len(nb) for nb in nbr]), 1)[:, None]

    sunk = np.zeros(len(P), dtype=bool)
    tri = np.array([(f.verts[0].index, f.verts[k].index, f.verts[k + 1].index) for f in bm.faces for k in range(1, len(f.verts) - 1)])

    def normals(X):
        """The membrane's own vertex normals (it spans the creases, so they turn more smoothly
        than the skin's)."""
        fn = np.cross(X[tri[:, 1]] - X[tri[:, 0]], X[tri[:, 2]] - X[tri[:, 0]])
        acc = np.zeros_like(X)
        for c in range(3):
            np.add.at(acc, tri[:, c], fn)
        return acc / np.maximum(np.linalg.norm(acc, axis=1), 1e-12)[:, None]

    def lap(X):
        acc = np.zeros_like(X)
        np.add.at(acc, rows, X[cols])
        return acc / deg - X
    for k in range(iters):
        # first plain smoothing (spans the creases), then fairing steps (bi-Laplacian: bends
        # smoothly over a lone bump instead of tenting on it, so no groove rings the bump)
        step = 0.5 * lap(P) if k < iters // 3 else -0.25 * lap(lap(P))
        Q = np.where(free[:, None], P + step, P)
        N = normals(Q)
        for i in range(len(Q)):
            loc, nrm, _, _ = bvh.find_nearest(Vector(Q[i] * S))
            if loc is None:
                continue
            q, n = np.array(loc) / S, np.array(nrm)
            d = Q[i] - q
            L = np.linalg.norm(d)
            sd = L if d.dot(n) >= 0 else -L
            lo, hi = bounds(Q[i], n, N[i])
            sunk[i] = lo < 0.0
            if sd < lo:
                Q[i] = q + n * lo
            elif sd > hi:
                Q[i] = q + (d / L if sd > 0 else n) * hi
        P = Q
    for v, p in zip(bm.verts, P):
        v.co = Vector(p * S)
    bm.normal_update()
    # faces the squeeze folded over (turned away from the skin under them) would show as flat ink
    # slivers once inflated and flipped: dropped - the skin right under them hides the gap
    folded = []
    for f in bm.faces:
        loc, nrm, _, _ = bvh.find_nearest(f.calc_center_median())
        if (loc is not None and f.normal.dot(nrm) < 0.2) or (drop_sunk and any(sunk[v.index] for v in f.verts)):
            folded.append(f)
    bmesh.ops.delete(bm, geom=folded, context="FACES")
    bm.to_mesh(me)
    bm.free()
    me.update()
    return me


def _lint_tone(balls, solids):
    """Brightness of the fluff at points P (N x 3, model units; higher = lighter): the surface's
    up-facing (from the field, so it is smooth whatever the mesh) minus its ambient occlusion -
    rays cast over the hemisphere round the normal against the fluff, the basket (`solids`, meshes
    in model units) and the floor: nothing over a puff's round cap, a lot in the valley between two
    puffs and where the fluff rests on the rope or hangs against the wicker."""
    field = _field(balls)
    verts, polys = [], []
    for me in solids:
        o = len(verts)
        verts += [v.co.copy() for v in me.vertices]
        polys += [tuple(o + i for i in p.vertices) for p in me.polygons]
    o = len(verts)
    verts += [Vector((x * S, y * S, 0.0)) for x, y in ((-40, -40), (40, -40), (40, 40), (-40, 40))]
    polys.append((o, o + 1, o + 2, o + 3))
    bvh = BVHTree.FromPolygons(verts, polys)
    n_rays, ga = AO[0], math.pi * (3.0 - math.sqrt(5.0))
    dirs = []
    for k in range(n_rays):  # cosine-weighted directions round +Z
        u = (k + 0.5) / n_rays
        r = math.sqrt(u)
        dirs.append(Vector((r * math.cos(k * ga), r * math.sin(k * ga), math.sqrt(1.0 - u))))
    reach = AO[1] * S

    def tone(P):
        P = np.asarray(P, dtype=float).reshape(-1, 3) / S
        _, g = field(P)
        n = -g / np.maximum(np.linalg.norm(g, axis=1), 1e-9)[:, None]
        ao = np.zeros(len(P))
        for i in range(len(P)):
            nv = Vector(n[i])
            rot = nv.to_track_quat("Z", "X").to_matrix()
            org = Vector(P[i] * S) + nv * (AO[2] * S)
            acc = 0.0
            for d in dirs:
                hit = bvh.ray_cast(org, rot @ d, reach)
                if hit[0] is not None:
                    acc += 1.0 - hit[3] / reach
            ao[i] = acc / n_rays
        return n[:, 2] - AO[3] * ao
    return tone


def _ramp_uvs(body, tone):
    """Paints the fluff's tones: every face coloured with FLUFF[0] (all of the fluff) gets, at each
    corner, a UV that slides along the ramp's palette row by the brightness there - the
    crease/shade edge at FLUFF_LEVELS[0], the shade/lit edge at FLUFF_LEVELS[1] - so the palette's
    swatch edges draw the tone contours across the triangles, with no extra triangles. The
    brightness is first blurred in 3D (Gaussian, TONE_BLUR studs), so the tone edges run as round
    crescents under each puff instead of zig-zagging with the occlusion's ray noise."""
    me = body.data
    uv = me.uv_layers["UVMap"].data
    u0, v0 = K.swatch_uv(FLUFF[0])
    polys = [poly for poly in me.polygons
             if abs(uv[poly.loop_start].uv[0] - u0) < 1e-4 and abs(uv[poly.loop_start].uv[1] - v0) < 1e-4]
    verts = sorted({vi for poly in polys for vi in poly.vertices})
    P = np.array([me.vertices[i].co for i in verts]) / S
    raw = np.asarray(tone([me.vertices[i].co for i in verts]))
    sm = np.empty(len(P))
    for k in range(0, len(P), 1024):
        d2 = ((P[k:k + 1024, None, :] - P[None, :, :]) ** 2).sum(-1)
        w = np.exp(-d2 / (2.0 * TONE_BLUR ** 2))
        sm[k:k + 1024] = (w * raw[None, :]).sum(1) / w.sum(1)
    b = dict(zip(verts, sm))
    l0, l1 = FLUFF_LEVELS
    for poly in polys:
        for li in poly.loop_indices:
            t = 0.5 + (b[me.loops[li].vertex_index] - l0) / (l1 - l0)  # swatch centres at t = 0, 1, 2
            uv[li].uv = (u0 + min(max(t, -1.4), 3.4) / K.GRID, v0)  # the doubled end swatches hold t outside
    return [poly.index for poly in polys]


def _catmull(ctrl, n):
    """n points along a Catmull-Rom spline through the control points (studs)."""
    C = [np.array(c, dtype=float) for c in ctrl]
    C = [2 * C[0] - C[1]] + C + [2 * C[-1] - C[-2]]
    out = []
    for k in range(n):
        t = k / (n - 1) * (len(ctrl) - 1)
        i = min(int(t), len(ctrl) - 2)
        s = t - i
        p0, p1, p2, p3 = C[i], C[i + 1], C[i + 2], C[i + 3]
        out.append(0.5 * (2 * p1 + (p2 - p0) * s + (2 * p0 - 5 * p1 + 4 * p2 - p3) * s * s
                          + (3 * p1 - p0 * 1 - 3 * p2 + p3) * s ** 3))
    return np.array(out)


def _resample(path, step):
    """The polyline `path` (N x 3) resampled at even steps of about `step` studs."""
    s = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(path, axis=0), axis=1))])
    n = max(int(round(s[-1] / step)) + 1, 4)
    return np.array([np.interp(np.linspace(0, s[-1], n), s, path[:, i]) for i in range(3)]).T


def _snap(field, P, steps=4):
    """Points (studs) moved onto the field's surface (Newton steps along the gradient, each at most
    half a stud long: where the field is nearly flat a full step would fling a point away)."""
    for _ in range(steps):
        f, g = field(P)
        step = (f / np.maximum((g * g).sum(1), 1e-9))[:, None] * g
        P = P - step * np.minimum(1.0, 0.5 / np.maximum(np.linalg.norm(step, axis=1), 1e-9))[:, None]
    return P


def _tube_mesh(name, P, radii, sides=4):
    """A smooth open tube (model units) through the points P (studs) with per-point radii (studs),
    each end closed by a cone tip: the sock threads."""
    n = len(P)
    T = np.gradient(P, axis=0)
    T /= np.linalg.norm(T, axis=1)[:, None]
    verts, faces = [], []
    nv = None
    for i in range(n):
        t = Vector(T[i])
        nv = t.orthogonal().normalized() if nv is None else (nv - t * nv.dot(t)).normalized()
        bv = t.cross(nv)
        for j in range(sides):
            b = math.tau * j / sides
            verts.append(Vector(P[i]) + (nv * math.cos(b) + bv * math.sin(b)) * radii[i])
    for i in range(n - 1):
        for j in range(sides):
            a, b = i * sides + j, i * sides + (j + 1) % sides
            faces.append((a, b, b + sides, a + sides))
    for end, ring in ((P[0] - T[0] * radii[0] * 1.5, 0), (P[-1] + T[-1] * radii[-1] * 1.5, n - 1)):
        verts.append(Vector(end))
        k = len(verts) - 1
        for j in range(sides):
            a, b = ring * sides + j, ring * sides + (j + 1) % sides
            faces.append((b, a, k) if ring == 0 else (a, b, k))
    return _mesh(name, verts, faces, fix=True)


def _drop_faces(piece, gone):
    """Deletes the faces of a Piece for which gone(face index, [its vertices in studs]) is true
    (faces never seen, so no budget spent on them); keeps its colours and flat faces in step."""
    me = piece.mesh
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    dead = [f for f in bm.faces if gone(f.index, [v.co / S for v in f.verts])]
    gone_ids = {f.index for f in dead}
    alive = [i for i in range(len(bm.faces)) if i not in gone_ids]
    piece.face_pal = [piece.face_pal[i] for i in alive]
    if getattr(piece, "flat_faces", None):
        new = {old: k for k, old in enumerate(alive)}
        piece.flat_faces = [new[i] for i in piece.flat_faces if i in new]
    bmesh.ops.delete(bm, geom=dead, context="FACES")
    bm.to_mesh(me)
    bm.free()
    me.update()
    return piece


def _depth(field, P):
    """How deep (studs, roughly) points P (N x 3, studs) lie inside the field's surface (< 0: outside)."""
    f, g = field(np.asarray(P, dtype=float).reshape(-1, 3))
    return f / np.maximum(np.linalg.norm(g, axis=1), 1e-9)


def _strand(field, ctrl, pal, r=THREAD_R, dips=(), wave=0.8, waves=2.5, seg=0.8, tail=None, name="thread"):
    """A sock thread tangled in the fluff: a loose, gently wavy line through the control points
    (studs, on the skin), laid on the field's surface - smoothed and snapped back onto it again and
    again, so it rests on the fluff along its whole length, sagging into the creases it crosses to
    within SAG studs of their bottom (no arch in the air, no plunge into a deep crease) - lying
    THREAD_LIFT of its radius out of it, except at
    the dips (fractions of its length), where it dives DIP_DEPTH radii under the skin for about
    two studs and comes out again: caught inside the lint, not sprinkled on it. `tail(last point,
    its direction)` -> points (studs) of a free end hanging in the air after the last control point.
    The faces buried in the fluff are dropped."""
    P = _snap(field, _resample(_catmull(ctrl, 300), seg))
    s = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
    L = s[-1]
    _, g = field(P)
    n = -g / np.maximum(np.linalg.norm(g, axis=1), 1e-9)[:, None]
    T = np.gradient(P, axis=0)
    side = np.cross(n, T)
    side /= np.maximum(np.linalg.norm(side, axis=1), 1e-9)[:, None]
    fade = np.sqrt(np.clip(np.sin(math.pi * s / L), 0.0, 1.0))  # the waves die out toward the ends
    P = P + (wave * fade * np.sin(math.tau * waves * s / L))[:, None] * side
    P = _snap(field, P)
    for _ in range(12):  # smoothed, resting on the puffs and sagging into creases (never into the fluff)
        P[1:-1] += 0.5 * ((P[:-2] + P[2:]) / 2 - P[1:-1])
        Q = _snap(field, P)
        _, g = field(Q)
        n = -g / np.maximum(np.linalg.norm(g, axis=1), 1e-9)[:, None]
        P = Q + n * np.clip(((P - Q) * n).sum(1), 0.0, SAG)[:, None]
    off = np.full(len(P), THREAD_LIFT * r)
    for d in dips:
        x = np.clip(np.abs(s / L - d) * L / 1.1, 0.0, 1.0)  # a dip about 2.2 studs long
        off -= (THREAD_LIFT + DIP_DEPTH) * r * np.cos(x * math.pi / 2) ** 2
    P = P + n * (off[:, None] + np.zeros_like(P))
    radii = np.full(len(P), r)
    if tail is not None:
        extra = np.array(tail(P[-1], P[-1] - P[-2]))
        P = np.vstack([P, _resample(np.vstack([P[-1:], extra]), seg * 0.6)[1:]])
        radii = np.concatenate([radii, np.full(len(P) - len(radii), r)])
    radii[-1] = radii[0] = r * 0.7
    piece = K.Piece(_tube_mesh(name, P, radii), pal, outline=False, smooth=True, name=name)
    return _drop_faces(piece, lambda i, vs: min(_depth(field, vs)) > 0.06)


def _skin_point(field, az, el, lift=0.0):
    """The point (studs) where a ray from PIVOT (azimuth, elevation in degrees) leaves the skin,
    lifted `lift` studs along the surface normal."""
    a, e = math.radians(az), math.radians(el)
    d = np.array((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e)))
    ts = np.arange(30.0, 0.0, -0.05)
    f, _ = field(np.array(PIVOT)[None, :] + ts[:, None] * d[None, :])
    p = np.array(PIVOT) + d * ts[int(np.argmax(f > 0))]
    _, g = field(p[None, :])
    return p - g[0] / max(np.linalg.norm(g[0]), 1e-9) * lift


def _curl(p, d):
    """The pink thread's free end: it leaves the tongue's drip, hangs down a little and ends in one
    loose open hook - yarn, not a worm."""
    out = np.array((p[0], p[1], 0.0)) / max(math.hypot(p[0], p[1]), 1e-9)
    tan = np.array((-out[1], out[0], 0.0))
    z = np.array((0.0, 0.0, 1.0))
    a = p + out * 0.3 - z * 0.7 + tan * 0.1
    c = a + out * 0.1 - z * 0.6 + tan * 0.5  # centre of the hook
    return [a] + [c + 0.5 * (math.cos(t) * -tan + math.sin(t) * z) for t in np.linspace(0.6, -3.3, 6)[1:]]


def _strands(balls):
    """Three long, loose sock threads tangled in the fluff - blue over the crown's front-left, pink
    draped down the big tongue and hanging off its drip in one open hook, yellow across the
    back-right - each dipping in and out of the fluff every few studs. Placed unevenly so together
    they never read as a face. This lint came from socks."""
    field = _field(balls)

    def path(*pts):
        return [_skin_point(field, az, el) for az, el in pts]
    return [
        _strand(field, path((-74, 24), (-55, 29), (-36, 35), (-16, 37), (4, 42)), FIB_BLUE, dips=(0.62,), waves=3.0),
        _strand(field, path((-100, 34), (-117, 27), (-134, 18), (-148, 9), (-149, -4)), FIB_PINK,
                dips=(0.36,), waves=3.0, tail=_curl),
        _strand(field, path((40, 43), (62, 39), (86, 36), (108, 30), (128, 31)), FIB_YELLOW, dips=(0.45,), waves=3.0),
    ]


def _round_normals(body, polys, field):
    """Custom split normals from the metaball field's analytic gradient on the fluff's corners:
    the lint shades perfectly round whatever its triangle count (no facets, no planar patches).
    The GLB carries them; every other face keeps its own (zero = automatic)."""
    me = body.data
    lidx = np.array([li for i in polys for li in me.polygons[i].loop_indices])
    vidx = np.array([me.loops[li].vertex_index for li in lidx])
    _, g = field(np.array([me.vertices[i].co for i in vidx]) / S)
    N = np.zeros((len(me.loops), 3))
    N[lidx] = -g / np.maximum(np.linalg.norm(g, axis=1), 1e-9)[:, None]
    me.normals_split_custom_set([tuple(v) for v in N])
    me.update()


def _flatten(me):
    """Squashes a mesh (model units) flat on the floor: faces wholly below it are dropped, the
    rest is clamped to z >= 0 (the dust bunny sits on the floor instead of balancing on it)."""
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if all(v.co.z < 0.0 for v in f.verts)], context="FACES")
    for v in bm.verts:
        v.co.z = max(v.co.z, 0.0)
    bm.to_mesh(me)
    bm.free()
    me.update()
    return me


def _bvh(meshes):
    verts, polys = [], []
    for me in meshes:
        o = len(verts)
        verts += [v.co.copy() for v in me.vertices]
        polys += [tuple(o + i for i in p.vertices) for p in me.polygons]
    return BVHTree.FromPolygons(verts, polys)


def _lint(solids):
    """-> (the fluff pieces and threads, the fluff's outline-only twins, the tone function, the
    fluff's field). The twins draw one hull round the fluff's silhouette (outline only: the painted
    pieces draw none)."""
    heap_balls, _ = _heap_balls()
    floor_balls = _floor_balls()
    heap = _metaballs(heap_balls, HEAP_TRIS, MB_RES, _in_basket)
    floor = _flatten(_metaballs(floor_balls, FLOOR_TRIS, MB_RES * 0.5))
    inks = []
    for balls, n, res, hid, bounds in ((heap_balls, INK_TRIS, MB_RES, _in_basket, _ink_bounds),
                                       (floor_balls, FLOOR_INK_TRIS, MB_RES * 0.5, None, lambda p, n, m: (INK_FIT, INK_EDGE))):
        skin = _polygonise(balls, res * 0.8)
        twin = _membrane(_metaballs(balls, n, res, hid), skin, bounds, drop_sunk=hid is not None)
        if hid is None:
            twin = _flatten(twin)
        else:
            twin = _cull_inner(twin, [heap, floor], solids, INK_W * S)
        inks.append(K.Piece(twin, K.OUTLINE, outline=True, smooth=True, name="lint_ink"))
        bpy.data.meshes.remove(skin)
    pieces = [K.Piece(heap, FLUFF[0], outline=False, smooth=True, name="lint"),
              K.Piece(floor, FLUFF[0], outline=False, smooth=True, name="lint_floor")]
    field = _field(heap_balls + floor_balls)
    return pieces + _strands(heap_balls), inks, _lint_tone(heap_balls + floor_balls, [heap, floor] + solids), field


def _drop_unseen(pieces, others):
    """Drops the faces of `pieces` that no camera can see - from any direction round, from 45
    degrees below to straight overhead, never from under the floor: the rope's inner half and the
    top buried under the lint, the foot ring's underside, the bottom disc inside the basket (not
    the woven wall: its deep seams are seen through narrow angles a coarse test misses). Every
    corner of a face (pulled a little toward its centre) and its centre are tested against all the
    body's meshes and the floor; a face any of them can see stays. Frees triangles for the lint."""
    bvh = _bvh([q.mesh for q in pieces + others] + [_floor_plane()])
    dirs = []
    for el in range(-45, 91, 15):
        for az in range(0, 360, 15 if el < 90 else 360):
            a, e = math.radians(az), math.radians(el)
            dirs.append(Vector((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e))))
    for q in pieces:
        me = q.mesh

        def seen(f):
            c = Vector(f.center)
            pts = [c] + [me.vertices[i].co * 0.85 + c * 0.15 for i in f.vertices]
            for d in dirs:
                if d.dot(f.normal) <= 0.0:
                    continue
                for pt in pts:
                    if bvh.ray_cast(pt + f.normal * (0.02 * S), d)[0] is None:
                        return True
            return False
        hidden = {f.index for f in me.polygons if not seen(f)}
        _drop_faces(q, lambda i, vs, _h=hidden: i in _h)
    return pieces


def _floor_plane():
    me = bpy.data.meshes.new("floor_plane")
    me.from_pydata([(x * S, y * S, 0.0) for x, y in ((-60, -60), (60, -60), (60, 60), (-60, 60))], [], [(0, 1, 2, 3)])
    return me


def _no_bounce(outline):
    """Preview only (Cycles ray flags, not exported): the inverted hull must not block bounce light,
    or renders show black wedges in corners and darkened insides that Roblox never draws."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False


def build():
    p = [_weave()]
    # bottom disc and foot ring
    p.append(K.cylinder(TAN_D, (R0 + 0.2) * S, 0.6 * S, M((0, 0, 0.9 * S)), seg=24, outline=False, name="floor"))
    foot = K.torus(TAN_D, (R0 + 0.2) * S, 1.1 * S, M((0, 0, 1.1 * S)), seg=24, mseg=6, name="foot")
    p.append(K.recolor_by(foot, lambda c, cur: TAN_M if c.z > 1.3 * S else TAN_D))
    # rolled rim with broad diagonal binding and the two hand holes (+-X); the rope's outline comes
    # from a smooth tube (outline only), the woven wall's from a smooth envelope
    rim, rim_ink = _rim()
    p.append(rim)
    inks = [_weave_ink(), rim_ink]
    for side in (1, -1):
        p += _handle(side)
    # the lint: one continuous fluffy skin heaped over the rim, spilling over it in two soft
    # tongues, with sock threads tangled in it; a loose wad and two small balls of fluff on the floor
    lint, lint_inks, tone, field = _lint([p[0].mesh, rim.mesh])
    _drop_unseen(p[1:4], p[:1] + p[4:] + lint)  # faces no camera can see: their triangles go to the lint
    p += lint
    inks += lint_inks
    body, outline = K.finish(p, NAME, outline_width=INK_W * S, outline_only=inks)
    _round_normals(body, _ramp_uvs(body, tone), field)
    _no_bounce(outline)
    return [body, outline] + K.markers(NAME)
