"""
props/curtains.py - the Curtains prop (ReplicatedStorage.MapMeshes.Curtains): night-blue starry
curtains framing the round moon window. See props/__init__.py for the conventions every prop follows.

A chunky wooden curtain rod with ball finials across the top; a scalloped swag valance over it (five
puffed swags, a cream lining hem along the scallops and little gold pom-poms at the points between
them); two pleated drapes hanging to the floor, each tied back with a gold ribbon and bow into a soft
curve (the fabric bunches at the tie and flares below it). Deep night-blue fabric printed with small
raised yellow stars and crescent moons; the cream lining shows along the drapes' inner edges, hems
and cut edges. The middle stays open (about 3.7 of the 8 units = ~150 of 320 studs at the top) - the
Window is a separate prop placed there.

Wall-mounted: the back is flat on the wall at y = 0, the front faces -Y; origin = bottom centre of the
back plane. Solid size 7.88 W x 5.91 H x 0.56 D units (Map fit box 320 x 240 x 24; the hull is left out
of the fit, as MeshTemplate.SolidBounds does).
Exported: `Curtains` (textured body), `Curtains_Outline` (inverted hull) and the markers.
"""
import math
import random
import bmesh
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Curtains"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"curtains_wood": "wood"}  # the rod
EXPORT_DIR = "map"

# ---------------------------------------------------------------- palette
FAB = hexcol("curtains_fabric", "#2A4098")          # deep night blue
FAB_L = hexcol("curtains_fabric_light", "#3D5BBA")  # folds facing the light / top-facing puffs
FAB_D = hexcol("curtains_fabric_dark", "#1F2E72")   # folds turned away, undersides
LINING = hexcol("curtains_lining", "#F3E5C8")       # cream lining
LINING_D = hexcol("curtains_lining_dark", "#D3BE9A")
STAR = hexcol("curtains_star", "#FFD45A")
MOON = hexcol("curtains_moon", "#FFE89E")
GOLD = hexcol("curtains_ribbon", "#F2BC45")
GOLD_L = hexcol("curtains_ribbon_light", "#FFDA7C")
GOLD_D = hexcol("curtains_ribbon_dark", "#C28A2A")
WOOD = hexcol("curtains_wood", "#C8693A")
WOOD_L = hexcol("curtains_wood_light", "#EC9A58")
WOOD_D = hexcol("curtains_wood_dark", "#8E4529")

# ---------------------------------------------------------------- layout (units; Z up, front = -Y, wall at y = 0)
OUT = 0.07              # ink width (~0.9% of the width)
X_OUT = 3.42            # drapes' outer edge
Z_DTOP = 5.45           # drapes' top (hidden behind the valance)
X_TOP = 1.86            # inner edge at the top -> open middle 3.72
Z_TIE, X_TIE = 2.35, 2.82   # the tie-back: height and the inner edge there (the gathered bundle)
X_BOT = 2.28            # inner edge at the hem
NF = 3.5                # folds across a drape (valley at the wall-side edge, crest at the inner edge)
D0 = 0.05               # gap between the wall and the fold valleys
T_FAB = 0.05            # fabric thickness
ROD_Y, ROD_Z, ROD_R = -0.26, 5.48, 0.09
VAL_X = 3.46            # valance half-width
VAL_TOP, VAL_CUSP, VAL_DIP = 5.85, 4.98, 0.34   # valance top, scallop points, scallop depth
VAL_BACK = -0.19        # valance back plane
N_SWAG = 5
LIGHT = Vector((-0.55, -0.62, 0.56)).normalized()   # toon light from the upper left (the lamp side)


# ---------------------------------------------------------------- helpers
def _toon(n, base, light, dark, hi=0.74, lo=0.30):
    d = n.dot(LIGHT)
    return light if d > hi else dark if d < lo else base


def _slab_grid(front, back, tags_front, side_pal, name, outline=True, flat_back=False):
    """A closed slab between two vertex grids [row][col] (front faces -Y side, back toward the wall).
    Faces: front quads coloured by tags_front(i, j, normal), back quads and the four rim strips `side_pal`.
    flat_back: the back grid is planar (on one y) - it becomes ONE polygon round the rim (cheap).
    Returns the Piece."""
    bm = bmesh.new()
    nr, nc = len(front), len(front[0])
    rim = [(0, j) for j in range(nc)] + [(i, nc - 1) for i in range(1, nr)] + \
          [(nr - 1, j) for j in range(nc - 2, -1, -1)] + [(i, 0) for i in range(nr - 2, 0, -1)]
    F = [[bm.verts.new(v) for v in row] for row in front]
    if flat_back:
        B = [[None] * nc for _ in range(nr)]
        for i, j in rim:
            B[i][j] = bm.verts.new(back[i][j])
    else:
        B = [[bm.verts.new(v) for v in row] for row in back]
    kinds = []
    for i in range(nr - 1):
        for j in range(nc - 1):
            bm.faces.new((F[i][j], F[i + 1][j], F[i + 1][j + 1], F[i][j + 1]))
            kinds.append(("f", i, j))
            if not flat_back:
                bm.faces.new((B[i][j], B[i][j + 1], B[i + 1][j + 1], B[i + 1][j]))
                kinds.append(("b", i, j))
    if flat_back:
        bm.faces.new([B[i][j] for i, j in reversed(rim)])
        kinds.append(("b", 0, 0))
    for k in range(len(rim)):
        a, b = rim[k], rim[(k + 1) % len(rim)]
        bm.faces.new((F[a[0]][a[1]], B[a[0]][a[1]], B[b[0]][b[1]], F[b[0]][b[1]]))
        kinds.append(("r", a, b))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = K._bm_to_mesh(bm, name)
    pal = []
    for f, kd in zip(me.polygons, kinds):
        if kd[0] == "f":
            pal.append(tags_front(kd[1], kd[2], f.normal))
        else:
            pal.append(side_pal)
    return K.Piece(me, pal, outline, True, name)


def _grid_eval(grid, fi, fj):
    """Bilinear point + normal on a vertex grid at fractional (row, col) - exactly on the faceted mesh."""
    nr, nc = len(grid), len(grid[0])
    i = min(max(int(fi), 0), nr - 2)
    j = min(max(int(fj), 0), nc - 2)
    a, b = fi - i, fj - j
    p00, p01, p10, p11 = grid[i][j], grid[i][j + 1], grid[i + 1][j], grid[i + 1][j + 1]
    p = p00 * (1 - a) * (1 - b) + p01 * (1 - a) * b + p10 * a * (1 - b) + p11 * a * b
    du = (p01 - p00) * (1 - a) + (p11 - p10) * a
    dv = (p10 - p00) * (1 - b) + (p11 - p01) * b
    n = du.cross(dv)
    if n.y > 0:
        n = -n
    return p, n.normalized()


def _decal(shape, place, pal, name, lift=0.016):
    """A flat printed shape on the fabric: `shape` = (outline points [(dx, dz)], faces as index tuples),
    `place(dx, dz)` -> (point, normal) on the front surface. Single-sided, facing out of the fabric."""
    pts, faces = shape
    bm = bmesh.new()
    vs = []
    nrm = Vector((0, 0, 0))
    for dx, dz in pts:
        p, n = place(dx, dz)
        vs.append(bm.verts.new(p + n * lift))
        nrm += n
    for idx in faces:
        f = [vs[i] for i in idx]
        a, b, c = (v.co for v in f[:3])
        if (b - a).cross(c - a).dot(nrm) < 0:
            f = f[::-1]
        try:
            bm.faces.new(f)
        except ValueError:
            pass
    return K.Piece(K._bm_to_mesh(bm, name), pal, False, False, name)


def _star_shape(r, rot):
    pts = [(0.0, 0.0)]
    for k in range(10):
        a = rot + math.pi / 2 + k * math.pi / 5
        rr = r if k % 2 == 0 else r * 0.46
        pts.append((rr * math.cos(a), rr * math.sin(a)))
    faces = [(0, 1 + k, 1 + (k + 1) % 10) for k in range(10)]
    return pts, faces


def _moon_shape(r, rot, n=8):
    """A crescent opening to the right (rotated by `rot`): a strip between the outer arc and the bite."""
    ca, sa = math.cos(rot), math.sin(rot)
    bc, br = (0.45 * r, 0.16 * r), 0.8 * r
    # tips: where the bite circle meets the outer circle
    d = math.hypot(*bc)
    a = (r * r - br * br + d * d) / (2 * d)
    h = math.sqrt(max(r * r - a * a, 0))
    mx, my = a * bc[0] / d, a * bc[1] / d
    t1 = (mx - h * bc[1] / d, my + h * bc[0] / d)
    t2 = (mx + h * bc[1] / d, my - h * bc[0] / d)
    if t1[1] < t2[1]:
        t1, t2 = t2, t1
    a0, a1 = math.atan2(t1[1], t1[0]), math.atan2(t2[1], t2[0])
    while a1 < a0:
        a1 += math.tau
    b0, b1 = math.atan2(t1[1] - bc[1], t1[0] - bc[0]), math.atan2(t2[1] - bc[1], t2[0] - bc[0])
    while b1 < b0:
        b1 += math.tau
    outer = [(r * math.cos(a0 + (a1 - a0) * k / n), r * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]
    inner = [(bc[0] + br * math.cos(b0 + (b1 - b0) * k / n), bc[1] + br * math.sin(b0 + (b1 - b0) * k / n)) for k in range(n + 1)]
    pts = outer + inner[1:-1]
    # index of inner[k] (k = 1..n-1) is n + k; inner[0] = outer[0], inner[n] = outer[n]
    ii = lambda k: 0 if k == 0 else (n if k == n else n + k)
    faces = []
    for k in range(n):
        q = [k, k + 1, ii(k + 1), ii(k)]
        q = [v for m, v in enumerate(q) if v not in q[:m]]
        if len(q) >= 3:
            faces.append(tuple(q))
    rotp = [(x * ca - y * sa, x * sa + y * ca) for x, y in pts]
    return rotp, faces


def _paint(piece, base, light=None, dark=None, up=0.55, down=-0.55):
    pals = []
    for f in piece.mesh.polygons:
        nz = f.normal.z
        pals.append(light if (light is not None and nz > up) else dark if (dark is not None and nz < down) else base)
    piece.face_pal = pals
    return piece


def _frame(t, n, z=Vector((0, 0, 1))):
    """4x4 matrix whose local X = t, Y = n, Z = up (orthonormalised)."""
    t = t.normalized()
    up = n.cross(t).normalized() if n.cross(t).length > 1e-6 else z
    if up.dot(z) < 0:
        up = -up
    n2 = up.cross(t).normalized()
    m = Matrix((t, n2, up)).transposed().to_4x4()
    return m


# ---------------------------------------------------------------- the drapes
def _x_inner(z):
    if z >= Z_TIE:
        t = (z - Z_TIE) / (Z_DTOP - Z_TIE)
        return X_TIE - (X_TIE - X_TOP) * (1 - (1 - t) ** 2)
    return X_BOT + (X_TIE - X_BOT) * (z / Z_TIE) ** 3


def _amp(z):
    base = 0.15 + 0.04 * (1 - z / Z_DTOP)
    return base + 0.045 * math.exp(-((z - Z_TIE) / 0.55) ** 2)


def _bulge(z):
    return 0.05 * math.exp(-((z - Z_TIE) / 0.5) ** 2)


def _drape_point(u, z, s):
    xi = _x_inner(z)
    w = X_OUT - xi
    x = s * (X_OUT - u * w)
    fold = 0.5 - 0.5 * math.cos(math.tau * NF * u)
    y = -(D0 + _amp(z) * fold + _bulge(z) * math.sin(math.pi * u))
    return Vector((x, y, z))


def _drape_rows():
    zs = [Z_DTOP, 4.75] + [4.75 - (4.75 - 3.0) * k / 4 for k in range(1, 4)]  # upper drape (top behind the valance)
    zs += [3.0 - (3.0 - 1.75) * k / 7 for k in range(7)]              # bunched round the tie
    zs += [1.75 - (1.75 - 0.15) * k / 4 for k in range(5)] + [0.0]    # flare down to the cream hem band
    return zs


NU = 14  # columns across a drape (4 per fold; smooth shading rounds them)


def _drape(s, decals, rnd):
    zs = _drape_rows()
    us = [j / NU for j in range(NU + 1)]
    front = [[_drape_point(u, z, s) for u in us] for z in zs]
    back = [[v + Vector((0, T_FAB, 0)) for v in row] for row in front]
    nr = len(zs)

    def tag(i, j, n):
        if j >= NU - 1:                 # the cream lining turned out along the inner edge
            return LINING if n.dot(LIGHT) > 0.3 else LINING_D
        if i == nr - 2:                 # cream hem
            return LINING
        return _toon(n, FAB, FAB_L, FAB_D)
    piece = _slab_grid(front, back, tag, LINING, "drape")

    # printed stars and moons, in staggered rows, kept off the edges, the tie and the hem
    def place_fn(u0, z0):
        def place(dx, dz):
            z = z0 + dz
            w = X_OUT - _x_inner(z)
            u = u0 - s * dx / w
            # fractional row index
            fi = 0.0
            for i in range(nr - 1):
                if zs[i] >= z >= zs[i + 1]:
                    fi = i + (zs[i] - z) / (zs[i] - zs[i + 1])
                    break
            return _grid_eval(front, fi, u * NU)
        return place
    row = 0
    z = 4.85
    while z > 0.55:
        if abs(z - Z_TIE) > 0.42:
            w = X_OUT - _x_inner(z)
            n = max(1, int(round(w / 0.62)))
            for k in range(n):
                u = (k + 0.5 + (0.5 if row % 2 else 0.0)) / (n + 0.5)
                u += rnd.uniform(-0.05, 0.05)
                if not 0.1 < u < 0.86:
                    continue
                zz = z + rnd.uniform(-0.06, 0.06)
                if (k + row) % 3 == 1:
                    shape = _moon_shape(0.12, rnd.uniform(-0.6, 0.6) + (math.pi if s < 0 else 0.0))
                    decals.append(_decal(shape, place_fn(u, zz), MOON, "moon"))
                else:
                    shape = _star_shape(0.115, rnd.uniform(-0.4, 0.4))
                    decals.append(_decal(shape, place_fn(u, zz), STAR, "star"))
        z -= 0.56
        row += 1
    return piece


def _tieback(s, p, ink):
    """Gold ribbon band round the bunched drape at the tie, with a bow on its front-inner side."""
    xi = _x_inner(Z_TIE)
    xc, yc = s * (xi + X_OUT) / 2, -0.15
    ax = (X_OUT - xi) / 2 + 0.075
    # smallest ay that holds every point of the fabric's front at the tie, plus a margin
    ay = 0.0
    for j in range(61):
        q = _drape_point(j / 60, Z_TIE, s)
        e = 1 - ((q.x - xc) / ax) ** 2
        if e > 0.02:
            ay = max(ay, abs(q.y - yc) / math.sqrt(e))
    ay = min(ay + 0.04, 0.3)
    h, t, seg = 0.17, 0.04, 22
    bm = bmesh.new()
    rings = []
    for k in range(seg):
        a = k / seg * math.tau
        c = Vector((xc + ax * math.cos(a), yc + ay * math.sin(a), Z_TIE))
        n = Vector((math.cos(a) / ax, math.sin(a) / ay, 0)).normalized()
        ring = []
        for o, dz in ((0, -h / 2), (t, -h / 2 + 0.02), (t, h / 2 - 0.02), (0, h / 2)):
            q = c + n * o + Vector((0, 0, dz))
            q.y = min(q.y, -0.008 - (0.012 if o > 0 else 0.0))  # the back of the loop lies flat on the wall
            ring.append(bm.verts.new(q))
        rings.append(ring)
    for k in range(seg):
        r0, r1 = rings[k], rings[(k + 1) % seg]
        for m in range(4):
            m2 = (m + 1) % 4
            bm.faces.new((r0[m], r1[m], r1[m2], r0[m2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    band = K.Piece(K._bm_to_mesh(bm, "ribbon_band"), GOLD, True, False, "ribbon_band")
    p.append(_paint(band, GOLD, GOLD_L, GOLD_D))
    # the bow, on the band's front, a little toward the window
    a = math.radians(-90 - 32 * s)
    c = Vector((xc + ax * math.cos(a), yc + ay * math.sin(a), Z_TIE))
    n = Vector((math.cos(a) / ax, math.sin(a) / ay, 0)).normalized()
    tng = Vector((-n.y, n.x, 0))
    if tng.x < 0:
        tng = -tng
    F = _frame(tng, n)
    base = Matrix.Translation(c + n * (t + 0.02))
    knot = K.sphere(GOLD, 0.065, base @ F @ M(scale=(1.0, 0.7, 1.1)), seg=10, rings=6, outline=False, name="knot")
    p.append(_paint(knot, GOLD, GOLD_L, GOLD_D, up=0.5, down=-0.5))
    ink.append(K.sphere(0, 0.065 - OUT + 0.03, base @ F @ M(scale=(1.0, 0.7, 1.1)), seg=10, rings=6, name="knot_ink"))
    for side in (-1, 1):
        # loops: flattened rings lying in the bow plane, tilted up and out
        lm = base @ F @ M((side * 0.17, -0.005, 0.04), rot=(math.pi / 2, -side * 0.35, 0), scale=(1.0, 0.62, 1.0))
        loop = K.torus(GOLD, 0.14, 0.042, lm, seg=14, mseg=5, name="loop")
        p.append(_paint(loop, GOLD, GOLD_L, GOLD_D, up=0.5, down=-0.5))
        # tails hanging down from the knot, splaying out
        tm = base @ F @ M((side * 0.07, 0.0, -0.18), rot=(0, -side * 0.32, 0))
        tail = K.rounded_box(GOLD, (0.1, 0.03, 0.34), tm, bevel=0.012, segments=1, name="tail")
        p.append(_paint(tail, GOLD, GOLD_L, GOLD_D))


# ---------------------------------------------------------------- the valance
VAL_NC = 10 * N_SWAG  # columns


def _val_bottom(x):
    sw = 2 * VAL_X / N_SWAG
    t = ((x + VAL_X) / sw) % 1.0
    if x >= VAL_X - 1e-6:
        t = 0.0
    return VAL_CUSP - VAL_DIP * math.sin(math.pi * t) ** 0.65


def _val_point(x, v):
    sw = 2 * VAL_X / N_SWAG
    t = min(1.0, ((x + VAL_X) / sw) % 1.0) if x < VAL_X - 1e-6 else 0.0
    zb = _val_bottom(x)
    z = VAL_TOP - v * (VAL_TOP - zb)
    puff = 0.075 * math.sin(math.pi * t) ** 0.8 * (0.35 + 0.65 * v)
    roll = 0.05 * math.exp(-(v / 0.12) ** 2)  # the header rolls over the rod
    y = -(0.38 + puff + roll)
    return Vector((x, y, z))


def _valance(p, decals, ink):
    vs = [0.0, 0.07, 0.2, 0.42, 0.64, 0.84, 0.93, 1.0]
    xs = [-VAL_X + 2 * VAL_X * j / VAL_NC for j in range(VAL_NC + 1)]
    front = [[_val_point(x, v) for x in xs] for v in vs]
    # the header rolls over the top toward the wall (a soft rounded top, not a box edge)
    head = []
    for f_y, dz in ((0.3, 0.06), (0.72, 0.045)):
        head.append([Vector((q.x, VAL_BACK + (q.y - VAL_BACK) * f_y, q.z + dz)) for q in front[0]])
    nh = len(head)
    front = head + front
    back = [[Vector((q.x, VAL_BACK, q.z)) for q in row] for row in front]
    nr = len(front)

    def tag(i, j, n):
        if i == nr - 2:
            return LINING if n.z > -0.5 else LINING_D
        return _toon(n, FAB, FAB_L, FAB_D)
    p.append(_slab_grid(front, back, tag, LINING, "valance", flat_back=True))
    # a star in the middle of each swag, a little moon over each point between them
    sw = 2 * VAL_X / N_SWAG

    def place_fn(x0, v0):
        def place(dx, dz):
            x = x0 + dx
            zb = _val_bottom(x)
            v = (VAL_TOP - (_val_point(x0, v0).z + dz)) / (VAL_TOP - zb)
            fj = (x + VAL_X) / (2 * VAL_X) * VAL_NC
            fi = float(nh)
            for i in range(len(vs) - 1):
                if vs[i] <= v <= vs[i + 1]:
                    fi = nh + i + (v - vs[i]) / (vs[i + 1] - vs[i])
                    break
            return _grid_eval(front, fi, fj)
        return place
    for k in range(N_SWAG):
        xm = -VAL_X + (k + 0.5) * sw
        decals.append(_decal(_star_shape(0.15, 0.0), place_fn(xm, 0.5), STAR, "star"))
    for k in range(1, N_SWAG):
        xm = -VAL_X + k * sw
        decals.append(_decal(_moon_shape(0.1, 0.5 if k % 2 else -0.5), place_fn(xm, 0.4), MOON, "moon"))
        # gold pom-pom hanging under the point
        q = _val_point(xm, 1.0)
        pm = M((xm, q.y + 0.05, VAL_CUSP - 0.13))
        p.append(_paint(K.sphere(GOLD, 0.09, pm, seg=8, rings=5, outline=False, name="pompom"), GOLD, GOLD_L, GOLD_D, up=0.4, down=-0.4))
        ink.append(K.sphere(0, 0.09 - OUT + 0.03, pm, seg=8, rings=5, name="pompom_ink"))


# ---------------------------------------------------------------- the rod
def _rod(p):
    L = VAL_X + 0.14
    rod = K.cylinder(WOOD, ROD_R, 2 * L, M((0, ROD_Y, ROD_Z), rot=(0, math.pi / 2, 0)), seg=12, name="rod")
    p.append(_paint(rod, WOOD, WOOD_L, WOOD_D, up=0.5, down=-0.5))
    for s in (-1, 1):
        col = K.cylinder(WOOD_D, 0.125, 0.07, M((s * (L + 0.0), ROD_Y, ROD_Z), rot=(0, math.pi / 2, 0)), seg=12, name="collar")
        p.append(_paint(col, WOOD, WOOD_L, WOOD_D, up=0.5, down=-0.5))
        ball = K.sphere(WOOD, 0.17, M((s * (L + 0.17), ROD_Y, ROD_Z)), seg=12, rings=7, name="finial")
        p.append(_paint(ball, WOOD, WOOD_L, WOOD_D, up=0.45, down=-0.5))


def _camera_only(outline):
    """Cycles-only flags (no effect on the GLB / game): keep the hull from blocking bounce/sky light in
    the preview renders."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False


def build():
    p, decals, ink = [], [], []
    rnd = random.Random(7)
    for s in (1, -1):
        p.append(_drape(s, decals, rnd))
        _tieback(s, p, ink)
    _valance(p, decals, ink)
    _rod(p)
    body, outline = K.finish(p + decals, NAME, outline_width=OUT, outline_only=ink)
    _camera_only(outline)
    return [body, outline] + K.markers(NAME)
