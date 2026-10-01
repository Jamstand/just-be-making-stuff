"""
props/blocks.py - the Blocks prop (ReplicatedStorage.MapMeshes.Blocks): four wooden alphabet blocks
spelling S O C K in a loose row, as in docs/concept/bedroom_keyframe.png. See props/__init__.py for
the conventions every prop follows.

Each block is one bmesh cube: a thick rounded frame on every edge (the lit top tone covers the top
face and the upper half of each top bevel), a cream panel recessed into every face (a thin dark ink
step all round it) and a big chunky slab-serif letter raised from each panel (the four sides and the
top - the top letter reads from the front, like the art). The letters are built from 2D outlines
defined here (no font file: Blender's built-in font is a thin sans); S, C and K are traced from the art.
Every letter shape is extruded as a slab with sloped, smooth-shaded sides (the top shrunk inward) and
sits on a flat dark rim one ink-line wider than the letter - the art's dark letter outline.
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Blocks"

# colours sampled from the concept art (lit faces), per block: frame/letter base, lit top tone,
# shadow tone, ink (letter outline + the step round the panel)
B_RED = (hexcol("blocks_red", "#EC4034"), hexcol("blocks_red_light", "#FF6E58"),
         hexcol("blocks_red_dark", "#BC2E26"), hexcol("blocks_red_ink", "#4A1012"))
B_YEL = (hexcol("blocks_yellow", "#FFC41E"), hexcol("blocks_yellow_light", "#FFDE62"),
         hexcol("blocks_yellow_dark", "#D2941A"), hexcol("blocks_yellow_ink", "#5A300C"))
B_BLUE = (hexcol("blocks_blue", "#5876D2"), hexcol("blocks_blue_light", "#7C98E8"),
          hexcol("blocks_blue_dark", "#3F5BB0"), hexcol("blocks_blue_ink", "#1A1F48"))
PANEL = hexcol("blocks_panel", "#F6CD98")
PANEL_L = hexcol("blocks_panel_light", "#FADDAE")

# ---------------------------------------------------------------- 2D letter outlines
# Cap height ~1 (scaled by the art's letter-to-panel ratio), centred on (0, 0). A letter is a list of shapes
# {"outer": loop, "hole": loop|None}; loops are CCW lists of (x, y, corner) - corner=1 keeps a sharp vertex.
# Every letter is ONE shape, so it reads as one raised form with one clean ink rim.
#
# S, C and K are traced from the concept art (the front letters of docs/concept/bedroom_keyframe.png): the
# letter fill was vectorised, the perspective shear of each block face taken out (the face's top and
# bottom edges give the slope) and scaled by the panel height, so their weight, narrow slot counters and
# flared vertical-cut terminals are the art's own. The control points below are joined by a smooth
# Catmull-Rom curve (the K's straight edges are used as they are). The O is a fitted superellipse pair.
S_PTS = [
    (0.104, 0.505, 0), (-0.068, 0.512, 0), (-0.182, 0.496, 0), (-0.287, 0.432, 0), (-0.340, 0.358, 0), (-0.355, 0.291, 0),
    (-0.354, 0.195, 0), (-0.296, 0.059, 0), (-0.259, 0.019, 0), (-0.182, -0.032, 0), (0.074, -0.144, 0), (0.105, -0.171, 0),
    (0.122, -0.216, 0), (0.119, -0.264, 0), (0.089, -0.311, 0), (-0.015, -0.335, 0), (-0.079, -0.328, 0), (-0.143, -0.299, 0),
    (-0.204, -0.173, 1), (-0.343, -0.177, 1), (-0.351, -0.192, 0), (-0.343, -0.409, 0), (-0.326, -0.441, 0), (-0.284, -0.467, 0),
    (-0.049, -0.512, 0), (0.115, -0.502, 0), (0.176, -0.485, 0), (0.273, -0.426, 0), (0.340, -0.331, 0), (0.355, -0.266, 0),
    (0.343, -0.152, 0), (0.290, -0.037, 0), (0.171, 0.051, 0), (-0.063, 0.158, 0), (-0.110, 0.194, 0), (-0.131, 0.234, 0),
    (-0.130, 0.283, 0), (-0.099, 0.330, 0), (-0.057, 0.346, 0), (0.060, 0.352, 0), (0.118, 0.313, 0), (0.157, 0.191, 1),
    (0.284, 0.189, 1), (0.282, 0.429, 1), (0.196, 0.483, 0),
]
C_PTS = [
    (0.024, 0.503, 0), (-0.052, 0.496, 0), (-0.151, 0.466, 0), (-0.259, 0.401, 0), (-0.311, 0.352, 0), (-0.379, 0.244, 0),
    (-0.409, 0.145, 0), (-0.410, -0.100, 0), (-0.383, -0.198, 0), (-0.337, -0.297, 0), (-0.290, -0.364, 0), (-0.212, -0.425, 0),
    (-0.145, -0.459, 0), (-0.020, -0.495, 0), (0.168, -0.498, 0), (0.285, -0.468, 0), (0.407, -0.407, 1), (0.408, -0.270, 1),
    (0.384, -0.255, 0), (0.323, -0.251, 0), (0.227, -0.308, 0), (0.117, -0.327, 0), (0.047, -0.321, 0), (-0.058, -0.280, 0),
    (-0.118, -0.220, 0), (-0.153, -0.163, 0), (-0.189, -0.035, 0), (-0.188, 0.091, 0), (-0.162, 0.181, 0), (-0.121, 0.258, 0),
    (-0.058, 0.316, 0), (0.024, 0.336, 0), (0.178, 0.320, 0), (0.226, 0.277, 0), (0.265, 0.157, 1), (0.335, 0.144, 0),
    (0.381, 0.156, 1), (0.401, 0.238, 0), (0.390, 0.418, 1), (0.361, 0.449, 0), (0.236, 0.485, 0),
]
# K: one closed outline (all straight edges, every vertex sharp), traced from the art's K fill row by row:
# stem with both serifs (small chamfers where they meet the stem), the thin arm rising to its own top
# serif, a concave V between stem and arm, the thick leg branching off the underside of the arm and
# ending in a foot serif that reaches right only, and a second notch between leg and stem. One loop =
# one raised form with one ink rim (no overlapping slabs, so no creases where the parts cross).
K_PTS = [
    (-0.483, 0.484, 1), (-0.059, 0.484, 1), (-0.059, 0.350, 1), (-0.124, 0.350, 1), (-0.153, 0.319, 1), (-0.150, 0.052, 1),
    (0.147, 0.350, 1), (0.071, 0.350, 1), (0.071, 0.484, 1), (0.448, 0.484, 1), (0.448, 0.350, 1), (0.365, 0.350, 1),
    (0.095, 0.071, 1), (0.405, -0.356, 1), (0.483, -0.356, 1), (0.483, -0.484, 1), (0.204, -0.484, 1), (-0.077, -0.064, 1),
    (-0.153, -0.143, 1), (-0.153, -0.326, 1), (-0.112, -0.356, 1), (-0.059, -0.356, 1), (-0.059, -0.484, 1), (-0.483, -0.484, 1),
    (-0.483, -0.356, 1), (-0.430, -0.356, 1), (-0.389, -0.326, 1), (-0.389, 0.319, 1), (-0.418, 0.350, 1), (-0.483, 0.350, 1),
]
# O: outer and counter superellipses (centre x, centre y, rx, ry, exponent), fitted to the art's O
O_OUTER = (0.0, 0.0, 0.46, 0.49, 2.2)
O_HOLE = (0.005, 0.0, 0.23, 0.33, 2.4)


def _spline_loop(ctrl, step):
    """Closed centripetal Catmull-Rom loop through ctrl [(x, y, corner)], sampled about `step` apart; a
    corner stays one sharp vertex (the spans on both sides of it leave it straight)."""
    n = len(ctrl)
    out = []
    for i in range(n):
        p1, p2 = ctrl[i], ctrl[(i + 1) % n]
        p0 = p1 if p1[2] else ctrl[i - 1]
        p3 = p2 if p2[2] else ctrl[(i + 2) % n]
        out.append(tuple(p1))
        k = max(1, int(round(math.hypot(p2[0] - p1[0], p2[1] - p1[1]) / step)))
        knot = lambda a, b, t: t + max(math.hypot(b[0] - a[0], b[1] - a[1]), 1e-6) ** 0.5
        t0 = 0.0
        t1 = knot(p0, p1, t0) if p0 is not p1 else 1e-6
        t2 = knot(p1, p2, t1)
        t3 = knot(p2, p3, t2) if p3 is not p2 else t2 + 1e-6

        def lerp(a, b, ta, tb, t):
            u = (t - ta) / (tb - ta) if tb - ta > 1e-9 else 0.0
            return (a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u)

        for j in range(1, k):
            t = t1 + (t2 - t1) * j / k
            a1, a2, a3 = lerp(p0, p1, t0, t1, t), lerp(p1, p2, t1, t2, t), lerp(p2, p3, t2, t3, t)
            b1, b2 = lerp(a1, a2, t0, t2, t), lerp(a2, a3, t1, t3, t)
            c = lerp(b1, b2, t1, t2, t)
            out.append((c[0], c[1], 0))
    return out


def _superellipse(cx, cy, rx, ry, p, n):
    out = []
    for i in range(n):
        t = i / n * math.tau
        c, s = math.cos(t), math.sin(t)
        out.append((cx + rx * math.copysign(abs(c) ** (2 / p), c), cy + ry * math.copysign(abs(s) ** (2 / p), s), 0))
    return out


def _area(loop):
    return 0.5 * sum(loop[i][0] * loop[(i + 1) % len(loop)][1] - loop[(i + 1) % len(loop)][0] * loop[i][1]
                     for i in range(len(loop)))


def _ccw(loop):
    return loop if _area(loop) > 0 else loop[::-1]


def letter_shapes(ch, step=0.05):
    """The letter's shapes; curves are sampled about `step` (cap units) apart."""
    if ch == "O":
        n = max(24, 4 * int(round(2.95 / step / 4)))  # same count on both loops: the face between is quads
        return [{"outer": _superellipse(*O_OUTER, n), "hole": _superellipse(*O_HOLE, n)}]
    if ch == "S":
        return [{"outer": _ccw(_spline_loop(S_PTS, step)), "hole": None}]
    if ch == "C":
        return [{"outer": _ccw(_spline_loop(C_PTS, step)), "hole": None}]
    if ch == "K":
        return [{"outer": _ccw(K_PTS), "hole": None}]
    raise KeyError(ch)


def _offset(loop, dist):
    """Moves every vertex of a loop `dist` to the right of travel (outward for a CCW outer loop),
    mitred; the result has the same vertex count, so loops stay paired for quads."""
    n = len(loop)
    out = []
    for i in range(n):
        p0, p1, p2 = loop[i - 1], loop[i], loop[(i + 1) % n]
        e1 = (p1[0] - p0[0], p1[1] - p0[1])
        e2 = (p2[0] - p1[0], p2[1] - p1[1])
        l1 = math.hypot(*e1) or 1.0
        l2 = math.hypot(*e2) or 1.0
        n1 = (e1[1] / l1, -e1[0] / l1)
        n2 = (e2[1] / l2, -e2[0] / l2)
        bx, by = n1[0] + n2[0], n1[1] + n2[1]
        bl = math.hypot(bx, by) or 1.0
        bx, by = bx / bl, by / bl
        c = max(bx * n1[0] + by * n1[1], 0.45)
        out.append((p1[0] + bx * dist / c, p1[1] + by * dist / c))
    return out


# ---------------------------------------------------------------- 3D
SIDE = 1.0      # block edge
FRAME = 0.105   # flat frame width round each panel
STEP = 0.008    # the sloped step down into the panel (drawn in ink: a thin line, thinner than the outline)
RECESS = 0.03   # panel depth below the frame (shallow: no broad shadow band along the panel top)
BEVEL = 0.085   # rounded outer edges
BEVEL_SEG = 4   # even, so a loop runs along the middle of every bevel (where the lit top tone stops)
CAP = 0.6       # letter cap height: with its ink rim a letter fills ~83% of the panel, as measured on the art
RAISE = 0.022   # letter height above its ink rim (the letter top ends level with the frame)
CHAMFER = 0.01  # how far the letter top is shrunk -> sloped, pillowy sides
INK = 0.022     # dark rim round every letter
LETTER_Z = 0.01  # ink rim height above the panel (no z-fighting)

# face frames (centre normal n, letter right u, letter up v, curve sampling step in cap units); the top
# letter reads from the front. Faces the camera rarely sees (back, right) get coarser curves.
FACES = [((0, -1, 0), (1, 0, 0), (0, 0, 1), 0.055), ((0, 1, 0), (-1, 0, 0), (0, 0, 1), 0.16),
         ((-1, 0, 0), (0, -1, 0), (0, 0, 1), 0.075), ((1, 0, 0), (0, 1, 0), (0, 0, 1), 0.11),
         ((0, 0, 1), (1, 0, 0), (0, 1, 0), 0.055)]


def _tone(n, base, light, dark):
    """Frame tone from the block-local face normal by its dominant axis: the lit tone covers the top
    face and the upper half of every top bevel, split exactly on the bevel's middle loop (and on the
    diagonals of the corner patches), so the boundary is a clean line with no saw teeth."""
    h = max(abs(n.x), abs(n.y))
    return light if n.z > h + 1e-4 else (dark if -n.z > h + 1e-4 else base)


def _block_body(mat, cols):
    """One block: rounded cube, frame + ink step + cream panel on 5 faces (not the bottom)."""
    base, light, dark, ink = cols
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=SIDE)
    kind = bm.faces.layers.int.new("kind")
    for f in bm.faces:
        f[kind] = 0
    faces = [f for f in bm.faces if f.normal.z > -0.5]
    bmesh.ops.inset_individual(bm, faces=faces, thickness=FRAME, depth=0.0, use_even_offset=True)
    walls = bmesh.ops.inset_individual(bm, faces=faces, thickness=STEP, depth=-RECESS, use_even_offset=True)["faces"]
    for f in walls:
        f[kind] = 1
    for f in faces:
        f[kind] = 2
    h = SIDE / 2 - 1e-4
    outer = [e for e in bm.edges if all(abs(c) > h for v in e.verts for c in v.co)]
    bmesh.ops.bevel(bm, geom=outer + list({v for e in outer for v in e.verts}), offset=BEVEL, segments=BEVEL_SEG,
                    profile=0.5, affect="EDGES", clamp_overlap=True)
    bm.normal_update()
    pal, flat = [], []
    for i, f in enumerate(bm.faces):  # block-local normals: the tone split must not depend on the yaw
        if f[kind] == 2:
            pal.append(PANEL_L if f.normal.z > 0.9 else PANEL)
        elif f[kind] == 1:
            pal.append(ink)
        else:
            pal.append(_tone(f.normal, base, light, dark))
        if f[kind] or max(abs(c) for c in f.normal) > 0.999:
            flat.append(i)  # frame, step and panel are flat planes; only the bevels shade smooth
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    me = bpy.data.meshes.new("block")
    bm.to_mesh(me)
    bm.free()
    p = K.Piece(me, pal, outline=False, smooth=True, name="block")
    p.flat_faces = flat
    return p


def _letter_piece(shape, face_mat, cols):
    """One letter shape on a panel: a flat ink rim, then the letter as a slab with sloped sides. The
    sides are smooth-shaded on their own vertices (split at sharp corners), so the curves read round
    without dense sampling; the top and the rim stay flat."""
    base, _light, dark, ink = cols
    s = CAP
    z0, z1 = LETTER_Z, LETTER_Z + RAISE
    bm = bmesh.new()
    tags = []  # per face: "top" / "side" / "rim"

    def ring(loop, z):
        return [bm.verts.new((x, y, z)) for x, y in loop]

    def quads(a, b, tag, flip=False):
        n = len(a)
        for i in range(n):
            j = (i + 1) % n
            q = (a[i], a[j], b[j], b[i])
            bm.faces.new(q[::-1] if flip else q)
            tags.append(tag)

    def side_strip(bot, top, corners, flip=False):
        """Quads from bot (z0) up to top (z1) on fresh vertices; a corner vertex gets one copy per side."""
        n = len(bot)
        start, end = [], []
        for i in range(n):
            vb, vt = bm.verts.new((*bot[i], z0)), bm.verts.new((*top[i], z1))
            end.append((vb, vt))
            start.append((bm.verts.new((*bot[i], z0)), bm.verts.new((*top[i], z1))) if corners[i] else (vb, vt))
        for i in range(n):
            j = (i + 1) % n
            q = (start[i][0], end[j][0], end[j][1], start[i][1])
            bm.faces.new(q[::-1] if flip else q)
            tags.append("side")

    def loop_of(pts):
        return [(x * s, y * s) for x, y, _c in pts], [c for _x, _y, c in pts]

    outer, oc = loop_of(shape["outer"])
    otop = _offset(outer, -CHAMFER)
    ot = ring(otop, z1)
    quads(ring(_offset(outer, INK), z0), ring(outer, z0), "rim")
    side_strip(outer, otop, oc)
    if shape["hole"]:
        hole, hc = loop_of(shape["hole"])
        htop = _offset(hole, CHAMFER)
        quads(ot, ring(htop, z1), "top")
        side_strip(hole, htop, hc, flip=True)
        quads(ring(hole, z0), ring(_offset(hole, -INK), z0), "rim")
    else:
        bm.faces.new(ot)
        tags.append("top")
    bmesh.ops.transform(bm, matrix=face_mat, verts=bm.verts)
    bm.normal_update()
    pal, flat = [], []
    for i, (f, t) in enumerate(zip(bm.faces, tags)):
        if t == "rim":
            pal.append(ink)
        elif t == "top":
            pal.append(base)
        else:
            pal.append(dark if f.normal.z < -0.3 else base)  # soft pillow: only the under-edges darken
        if t != "side":
            flat.append(i)
    me = bpy.data.meshes.new("letter")
    bm.to_mesh(me)
    bm.free()
    p = K.Piece(me, pal, outline=False, smooth=True, name="letter")
    p.flat_faces = flat
    return p


def _face_matrix(block_mat, n, u, v):
    """Panel frame: x = letter right, y = letter up, z = out of the face, origin on the panel."""
    n, u, v = Vector(n), Vector(u), Vector(v)
    t = n * (SIDE / 2 - RECESS)
    m = Matrix(((u.x, v.x, n.x, t.x), (u.y, v.y, n.y, t.y), (u.z, v.z, n.z, t.z), (0, 0, 0, 1)))
    return block_mat @ m


# letter, colours, x, y, yaw - a loose row receding to the right, each block turned a little
# (the art shows S/O/C turned to show their left side, K nearly square-on). The spacing is irregular
# like the art: S tucked against O, O and C nearly touching, a wider gap before the K
# (closest gaps between footprints: S-O 0.09, O-C 0.14, C-K 0.25 block sides).
LAYOUT = [("S", B_RED, -1.94, -0.28, 0.62), ("O", B_YEL, -0.75, 0.0, 0.32),
          ("C", B_BLUE, 0.44, 0.10, 0.22), ("K", B_RED, 1.80, 0.26, -0.05)]


def build():
    pieces, hulls = [], []
    for ch, cols, x, y, yaw in LAYOUT:
        bmat = M((x, y, SIDE / 2), rot=(0, 0, yaw))
        pieces.append(_block_body(bmat, cols))
        hulls.append(K.rounded_box(cols[0], (SIDE, SIDE, SIDE), bmat, bevel=BEVEL, segments=3, name="hull"))
        for n, u, v, step in FACES:
            fm = _face_matrix(bmat, n, u, v)
            for shape in letter_shapes(ch, step):
                pieces.append(_letter_piece(shape, fm, cols))
    body, outline = K.finish(pieces, NAME, outline_width=0.022, outline_only=hulls)
    return [body, outline] + K.markers(NAME)
