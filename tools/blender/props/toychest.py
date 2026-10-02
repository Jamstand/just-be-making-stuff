"""
props/toychest.py - the ToyChest prop (ReplicatedStorage.MapMeshes.ToyChest): a painted wooden toy chest
for the expanded bedroom. See props/__init__.py for the conventions every prop follows.

Same toy language as the rest of the bedroom (docs/concept/bedroom_keyframe.png): chunky soft-edged
shapes, flat colours in 2-3 tones (lit tops, darker undersides) and thick ink outlines. A cheerful teal
chest with cream trim (top and bottom bands, corner posts, a border round the lid), brass corner caps,
hinges, side handles and a latch, a big yellow star painted on the front, little cream bun feet.
The lid is propped open (~32 degrees) on the toys inside - it rests on a striped beach ball - and the
chest is stuffed: a wooden toy sword stands hilt-up in the gap, an alphabet block teeters on the
front rim and an orange striped sock hangs over the rim down the front.

Units: 1 unit = 10 studs. Map.luau scales the prop uniformly so its visible bounds fit 90 x 60 x 55
studs (W x H x D); lid, toys and side handles included it is 9.05 x 6.05 x 4.9 units. Origin = floor
centre, front faces -Y. The sock comes from props/dresser.py's `sock()` sweep (same sock look on both
props). Also: a crescent moon and stars painted under the lid, toys heaped inside (only their tops show).
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
from props.dresser import sock

NAME = "ToyChest"

# ---- colours
TEAL = hexcol("toychest_teal", "#33B0A4")
TEAL_L = hexcol("toychest_teal_light", "#5ED0C1")
TEAL_D = hexcol("toychest_teal_dark", "#20807A")
TEAL_IN = hexcol("toychest_inside", "#1D4A50")       # inside walls
LID_IN = hexcol("toychest_lid_inside", "#2A6E6C")     # lid underside (catches a little light)
MOON = hexcol("toychest_moon", "#FFE9A8")
CREAM = hexcol("toychest_cream", "#F5E3BC")
CREAM_L = hexcol("toychest_cream_light", "#FFF3D8")
CREAM_D = hexcol("toychest_cream_dark", "#D3B98C")
BRASS = hexcol("toychest_brass", "#E2AE45")
BRASS_L = hexcol("toychest_brass_light", "#FFD780")
BRASS_D = hexcol("toychest_brass_dark", "#A9782A")
STAR = hexcol("toychest_star", "#FFD23F")
STAR_L = hexcol("toychest_star_light", "#FFE57A")
INK = K.OUTLINE
# toys
BALL_R = hexcol("toychest_ball_red", "#EC4034")
BALL_Y = hexcol("toychest_ball_yellow", "#FFC41E")
BALL_B = hexcol("toychest_ball_blue", "#4F7FD6")
BALL_W = hexcol("toychest_ball_white", "#FAF6EE")
BLOCK = hexcol("toychest_block", "#5876D2")
BLOCK_L = hexcol("toychest_block_light", "#7C98E8")
BLOCK_D = hexcol("toychest_block_dark", "#3F5BB0")
PANEL = hexcol("toychest_block_panel", "#F6CD98")
LETTER = hexcol("toychest_block_letter", "#EC4034")
LETTER_INK = hexcol("toychest_block_ink", "#4A1012")
BLADE = hexcol("toychest_sword_blade", "#E9C48A")
BLADE_L = hexcol("toychest_sword_blade_light", "#F6DDB0")
BLADE_D = hexcol("toychest_sword_blade_dark", "#BF925A")
GUARD = hexcol("toychest_sword_guard", "#D9443A")
GRIP = hexcol("toychest_sword_grip", "#3F5BB0")
POMMEL = hexcol("toychest_sword_pommel", "#FFC41E")
SOCK_O = hexcol("toychest_sock_orange", "#F7913A")
SOCK_OD = hexcol("toychest_sock_orange_dark", "#D9622B")
SOCK_CR = hexcol("toychest_sock_cream", "#FFF0D8")
SOCK_IN = hexcol("toychest_sock_inner", "#3A2F4E")
PILE = [hexcol("toychest_pile_red", "#E2584E"), hexcol("toychest_pile_green", "#6CC46A"),
        hexcol("toychest_pile_purple", "#A57BE0"), hexcol("toychest_pile_yellow", "#F2C14E"),
        hexcol("toychest_pile_brown", "#B97A45")]

# ---- dimensions (units)
BW, BD = 7.95, 4.3         # box body
FOOT_H = 0.3
RIM = 3.2                  # top of the box walls
WALL = 0.3
TRIM = 0.1                 # how far the cream trim stands proud
BAND_TOP = (RIM - 0.45, RIM + 0.03)
BAND_BOT = (FOOT_H, FOOT_H + 0.45)
LID_W, LID_D, LID_T = BW + 0.4, BD + 0.15, 0.5
HINGE_Y, HINGE_Z = BD / 2, RIM + 0.02
LID_OPEN = math.radians(32)
OUTLINE_W = 0.085          # ~1.4% of the height


# ---------------------------------------------------------------- helpers
def _tone(piece, base, light, dark, up=0.6, down=-0.6):
    piece.face_pal = [light if f.normal.z > up else (dark if f.normal.z < down else base) for f in piece.mesh.polygons]
    return piece


def _flat(piece):
    piece.smooth = False
    return piece


def _bevelled(bm, name, width, segments, angle_deg=30.0, mat=None):
    """bmesh -> baked world-space mesh with an angle-limited bevel (chamfer when segments=1)."""
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    K.link(obj)
    if mat is not None:
        obj.matrix_world = mat
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = width
    mod.segments = segments
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(angle_deg)
    mod.harden_normals = False
    return K.bake_object(obj)


def _box(pal, size, mat, bevel, segs=1, name="box", light=None, dark=None, outline=True):
    p = K.rounded_box(pal, size, mat, bevel=bevel, segments=segs, outline=outline, name=name)
    if light is not None:
        _tone(p, pal, light, dark)
    if segs == 1:
        p.smooth = False
    return p


def _prism(loop, depth, mat, pal, chamfer=0.0, name="prism", outline=True):
    """A 2D outline (x, y list, CCW) extruded `depth` along local -z (front face at z = 0), placed by mat."""
    bm = bmesh.new()
    vs = [bm.verts.new((x, y, 0.0)) for x, y in loop]
    f = bm.faces.new(vs)
    ret = bmesh.ops.extrude_face_region(bm, geom=[f])
    moved = [e for e in ret["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=Vector((0, 0, -depth)), verts=moved)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if chamfer:
        me = _bevelled(bm, name, chamfer, 1, mat=mat)
    else:
        bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
    return K.Piece(me, pal, outline=outline, smooth=False, name=name)


def _decal(loops, mat, pal, name="decal"):
    """Flat filled region (outer loop + optional hole loops) on local z = 0, facing local +z."""
    bm = bmesh.new()
    edges = []
    for loop in loops:
        vs = [bm.verts.new((x, y, 0.0)) for x, y in loop]
        for i in range(len(vs)):
            edges.append(bm.edges.new((vs[i], vs[(i + 1) % len(vs)])))
    bmesh.ops.triangle_fill(bm, use_beauty=True, use_dissolve=False, edges=edges, normal=(0, 0, 1))
    for f in bm.faces:
        if f.normal.z < 0:
            f.normal_flip()
    bmesh.ops.delete(bm, geom=[e for e in bm.edges if not e.link_faces], context="EDGES")
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pal, outline=False, smooth=False, name=name)


def _offset(loop, d):
    """Mitred offset of a CCW loop, d > 0 outward."""
    n = len(loop)
    out = []
    for i in range(n):
        p0, p1, p2 = Vector(loop[i - 1]), Vector(loop[i]), Vector(loop[(i + 1) % n])
        e1, e2 = (p1 - p0).normalized(), (p2 - p1).normalized()
        n1, n2 = Vector((e1.y, -e1.x)), Vector((e2.y, -e2.x))
        b = (n1 + n2)
        b = b.normalized() if b.length > 1e-6 else n1
        c = max(b.dot(n1), 0.35)
        q = p1 + b * (d / c)
        out.append((q.x, q.y))
    return out


def _crescent(R, seg=10):
    """CCW crescent moon outline (opening to the right): the outer circle's left arc, back along an
    inner circle's left arc."""
    a0 = math.radians(50)
    p1 = Vector((math.cos(a0), math.sin(a0))) * R
    cx = 0.45 * R
    r2 = math.hypot(p1.x - cx, p1.y)
    b0 = math.atan2(p1.y, p1.x - cx)
    pts = [(R * math.cos(a0 + (math.tau - 2 * a0) * i / seg), R * math.sin(a0 + (math.tau - 2 * a0) * i / seg))
           for i in range(seg + 1)]
    for i in range(1, seg):
        b = (math.tau - b0) - (math.tau - 2 * b0) * i / seg
        pts.append((cx + r2 * math.cos(b), r2 * math.sin(b)))
    return pts


def _star_loop(r_out, r_in, n=5, rot=math.pi / 2):
    return [((r_out if i % 2 == 0 else r_in) * math.cos(rot + i * math.pi / n),
             (r_out if i % 2 == 0 else r_in) * math.sin(rot + i * math.pi / n)) for i in range(2 * n)]


def _no_bounce(outline):
    """Preview only (Cycles ray flags, not exported): the inverted hull must not block bounce light."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False


# ---------------------------------------------------------------- chest
def _shell():
    """The box: one solid with the cavity cut into its top, softly bevelled; teal outside, dark inside,
    lit rim."""
    h = RIM - FOOT_H
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector((BW, BD, h)), verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector((0, 0, FOOT_H + h / 2)), verts=bm.verts)
    top = [f for f in bm.faces if f.normal.z > 0.9]
    bmesh.ops.inset_region(bm, faces=top, thickness=WALL, depth=0.0)
    ret = bmesh.ops.extrude_face_region(bm, geom=top)
    moved = [e for e in ret["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=Vector((0, 0, -(h - 0.35))), verts=moved)
    bmesh.ops.delete(bm, geom=top, context="FACES")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = _bevelled(bm, "shell", 0.1, 2)
    ix, iy = BW / 2 - WALL + 0.02, BD / 2 - WALL + 0.02
    pal = []
    for f in me.polygons:
        c, n = f.center, f.normal
        inside = abs(c.x) < ix and abs(c.y) < iy and c.z < RIM - 0.05
        if n.z > 0.6:
            pal.append(TEAL_IN if inside else TEAL_L)
        elif inside:
            pal.append(TEAL_IN)
        elif n.z < -0.6:
            pal.append(TEAL_D)
        else:
            pal.append(TEAL)
    p = K.Piece(me, pal, outline=True, smooth=True, name="shell")
    p.flat_faces = [i for i, f in enumerate(me.polygons) if f.area > 0.4]
    return p


def _ring(z0, z1):
    """The top band: a rectangular cream frame from the trim's outer face to the wall's inner face (so it
    caps the rim), softly bevelled; its inner faces take the dark inside colour."""
    xo, yo = BW / 2 + TRIM, BD / 2 + TRIM
    xi, yi = BW / 2 - WALL, BD / 2 - WALL
    bm = bmesh.new()
    loops = []
    for (x, y), z in (((xo, yo), z0), ((xo, yo), z1), ((xi, yi), z1), ((xi, yi), z0)):
        loops.append([bm.verts.new((sx * x, sy * y, z)) for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))])
    for a in range(4):
        la, lb = loops[a], loops[(a + 1) % 4]
        for i in range(4):
            j = (i + 1) % 4
            bm.faces.new((la[i], la[j], lb[j], lb[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = _bevelled(bm, "band_top", 0.07, 2)
    pal = []
    for f in me.polygons:
        c, n = f.center, f.normal
        inner = abs(c.x) < xi + 0.03 and abs(c.y) < yi + 0.03
        if n.z > 0.6:
            pal.append(CREAM_L)
        elif inner:
            pal.append(TEAL_IN)
        elif n.z < -0.6:
            pal.append(CREAM_D)
        else:
            pal.append(CREAM)
    p = K.Piece(me, pal, outline=True, smooth=True, name="band_top")
    p.flat_faces = [i for i, f in enumerate(me.polygons) if f.area > 0.3]
    return p


def _trims():
    """Cream bands round the top and bottom, cream corner posts, brass corner caps on top."""
    out = []
    W2, D2 = BW / 2 + TRIM, BD / 2 + TRIM
    out.append(_ring(BAND_TOP[0], BAND_TOP[1]))
    z0, z1 = BAND_BOT
    out.append(_box(CREAM, (BW + 2 * TRIM, BD + 2 * TRIM, z1 - z0), M((0, 0, (z0 + z1) / 2)), 0.07, 2, "band", CREAM_L,
                    CREAM_D))
    post = 0.55
    for sx in (-1, 1):
        for sy in (-1, 1):
            z0, z1 = BAND_BOT[1] - 0.05, BAND_TOP[0] + 0.05
            loc = (sx * (W2 - post / 2), sy * (D2 - post / 2), (z0 + z1) / 2)
            out.append(_box(CREAM, (post, post, z1 - z0), M(loc),
                            0.07, 2, "post", CREAM_L, CREAM_D))
            # brass corner cap over the top band's corner
            c = 0.78
            out.append(_box(BRASS, (c, c, BAND_TOP[1] - BAND_TOP[0] + 0.12),
                            M((sx * (W2 - c / 2 + 0.06), sy * (D2 - c / 2 + 0.06), (BAND_TOP[0] + BAND_TOP[1]) / 2)),
                            0.09, 1, "cap", BRASS_L, BRASS_D))
    # bun feet
    for sx in (-1, 1):
        for sy in (-1, 1):
            out.append(_tone(K.sphere(CREAM, 0.42, M((sx * (BW / 2 - 0.45), sy * (BD / 2 - 0.45), 0.42 * 0.72),
                                                     scale=(1, 1, 0.72)), seg=12, rings=7, name="foot"),
                             CREAM, CREAM_L, CREAM_D, up=0.5, down=-0.3))
    # brass side handles: a back plate and a chunky bar on each end
    for sx in (-1, 1):
        x = sx * (BW / 2 + TRIM)
        out.append(_box(BRASS, (0.12, 1.5, 0.5), M((x + sx * 0.04, 0, 2.1)), 0.04, 1, "handle_plate", BRASS_L, BRASS_D))
        out.append(_box(BRASS, (0.3, 1.7, 0.26), M((x + sx * 0.3, 0, 2.0)), 0.08, 2, "handle_bar", BRASS_L, BRASS_D))
        for sy in (-1, 1):
            out.append(_box(BRASS, (0.3, 0.22, 0.26), M((x + sx * 0.17, sy * 0.74, 2.0)), 0.06, 1, "handle_post",
                            BRASS_L, BRASS_D))
    # latch plate on the front of the top band
    yf = -(BD / 2 + TRIM)
    out.append(_box(BRASS, (0.75, 0.12, 0.62), M((0, yf - 0.04, BAND_TOP[0] + 0.2)), 0.05, 1, "latch", BRASS_L,
                    BRASS_D))
    out.append(_box(INK, (0.3, 0.1, 0.12), M((0, yf - 0.1, BAND_TOP[0] + 0.24)), 0.03, 1, "latch_slot", outline=False))
    return out


def _star():
    """A big yellow star painted on the front, on an ink rim (the art's dark outline round a decal)."""
    yf = -BD / 2
    zc = (BAND_BOT[1] + BAND_TOP[0]) / 2
    loop = _star_loop(0.82, 0.38)
    m = M((0, yf, zc), (math.pi / 2, 0, 0))  # local +z -> world -y
    out = [_decal([_offset(loop, 0.07)], m @ Matrix.Translation((0, 0, 0.012)), INK, "star_ink")]
    star = _prism(loop, 0.06, m @ Matrix.Translation((0, 0, 0.07)), STAR, chamfer=0.025, name="star", outline=False)
    star.face_pal = [STAR_L if f.normal.z > 0.3 else STAR for f in star.mesh.polygons]
    out.append(star)
    return out


def _lid_matrix():
    return M((0, HINGE_Y, HINGE_Z), (-LID_OPEN, 0, 0))


def _lid():
    """The lid, opened LID_OPEN about the back hinge: teal board, cream border on top, dark underside,
    brass front corners, a brass hasp hanging from the front edge, two hinges."""
    out = []
    m = _lid_matrix()
    # lid-local: x across, y from -LID_D (front edge) to 0 (hinge), z 0 (underside) .. LID_T
    board = K.rounded_box(TEAL, (LID_W, LID_D, LID_T), m @ M((0, -LID_D / 2, LID_T / 2)), bevel=0.12, segments=2,
                          name="lid")
    nrm_up = (m.to_3x3() @ Vector((0, 0, 1))).normalized()
    pal = []
    for f in board.mesh.polygons:
        d = f.normal.dot(nrm_up)
        if d > 0.6:
            pal.append(TEAL_L)
        elif d < -0.6:
            pal.append(LID_IN)
        elif f.normal.z < -0.5:
            pal.append(TEAL_D)
        else:
            pal.append(TEAL)
    board.face_pal = pal
    board.flat_faces = [i for i, f in enumerate(board.mesh.polygons) if f.area > 0.4]
    out.append(board)
    # cream border round the top face
    bw = 0.42
    zt = LID_T + 0.04
    for x in (-(LID_W / 2 - bw / 2 - 0.12), LID_W / 2 - bw / 2 - 0.12):
        out.append(_lid_trim(m, (bw, LID_D - 0.24, 0.12), (x, -LID_D / 2, zt), nrm_up))
    for y in (-LID_D + 0.12 + bw / 2, -0.12 - bw / 2):
        out.append(_lid_trim(m, (LID_W - 0.24 - 2 * bw + 0.02, bw, 0.12), (0, y, zt), nrm_up))
    # brass caps on the two front corners
    c = 0.8
    for sx in (-1, 1):
        cap = K.rounded_box(BRASS, (c, c, LID_T + 0.16), m @ M((sx * (LID_W / 2 - c / 2 + 0.06), -LID_D + c / 2 - 0.06,
                                                               LID_T / 2)), bevel=0.09, segments=1, name="lid_cap")
        cap.face_pal = [BRASS_L if f.normal.dot(nrm_up) > 0.6 or f.normal.z > 0.7 else
                        (BRASS_D if f.normal.z < -0.6 else BRASS) for f in cap.mesh.polygons]
        out.append(_flat(cap))
    # hasp hanging from the front edge (hinged, so it hangs straight down)
    edge = m @ Vector((0, -LID_D - 0.02, LID_T * 0.5))
    hasp = _box(BRASS, (0.5, 0.1, 0.85), M((edge.x, edge.y - 0.02, edge.z - 0.35)), 0.04, 1, "hasp", BRASS_L, BRASS_D)
    out.append(hasp)
    out.append(_box(INK, (0.2, 0.06, 0.32), M((edge.x, edge.y - 0.08, edge.z - 0.5)), 0.02, 1, "hasp_hole",
                    outline=False))
    # painted night sky on the underside: a crescent moon and little stars (decals face lid-local -z,
    # their "up" toward the lid's front edge)
    under = m @ M((0, 0, -0.012), (math.pi, 0, 0))
    moon = _crescent(0.62)
    mm = under @ Matrix.Translation((-1.05, 3.45, 0))
    out.append(_decal([_offset(moon, 0.05)], mm, INK, "moon_ink"))
    out.append(_decal([moon], mm @ Matrix.Translation((0, 0, 0.004)), MOON, "moon"))
    for x, y, r in ((-2.3, 3.75, 0.24), (0.15, 3.95, 0.2), (0.35, 2.7, 0.16), (3.55, 3.55, 0.26), (3.4, 2.2, 0.18)):
        st = _star_loop(r, r * 0.45)
        sm = under @ Matrix.Translation((x, y, 0))
        out.append(_decal([_offset(st, 0.045)], sm, INK, "lstar_ink"))
        out.append(_decal([st], sm @ Matrix.Translation((0, 0, 0.004)), STAR, "lstar"))
    # hinges: a brass barrel on the hinge line and a leaf down the box back
    for sx in (-2.6, 2.6):
        out.append(_flat(K.cylinder(BRASS_D, radius=0.14, depth=0.9, mat=M((sx, HINGE_Y + 0.08, HINGE_Z + 0.02),
                                                                           (0, math.pi / 2, 0)), seg=8, name="barrel")))
        out.append(_box(BRASS, (0.8, 0.08, 0.7), M((sx, BD / 2 + 0.04, HINGE_Z - 0.38)), 0.03, 1, "leaf", BRASS_L,
                        BRASS_D))
    return out


def _lid_trim(m, size, loc, nrm_up):
    p = K.rounded_box(CREAM, size, m @ M(loc), bevel=0.05, segments=1, name="lid_trim")
    p.face_pal = [CREAM_L if f.normal.dot(nrm_up) > 0.6 else (CREAM_D if f.normal.z < -0.5 else CREAM)
                  for f in p.mesh.polygons]
    return _flat(p)


def _lid_under(y_local):
    """World point on the lid's underside at lid-local y, and the underside's outward (down) normal."""
    m = _lid_matrix()
    p = m @ Vector((0, y_local, 0))
    n = (m.to_3x3() @ Vector((0, 0, -1))).normalized()
    return p, n


# ---------------------------------------------------------------- toys
def _ball():
    """A striped beach ball resting on the pile; the lid rests on it."""
    r = 1.05
    p, n = _lid_under(-3.05)
    c = p + n * (r + 0.01)
    c.x = 1.9
    mat = _frame_along(c, (-0.45, -0.55, 0.7), (1, 0, 0))  # pole tipped up / left / toward the viewer
    ball = K.sphere(BALL_R, r, mat, seg=24, rings=12, name="ball")
    inv = mat.inverted()
    cols = [BALL_R, BALL_W, BALL_B, BALL_W, BALL_Y, BALL_W]
    pal = []
    for f in ball.mesh.polygons:
        q = inv @ Vector(f.center)
        if abs(q.z) > r * 0.9:
            pal.append(BALL_R)
        else:
            a = (math.atan2(q.y, q.x) + math.tau) % math.tau
            pal.append(cols[int(a / (math.tau / 6)) % 6])
    ball.face_pal = pal
    return [ball]


A_OUTER = [(-0.5, -0.5), (-0.24, -0.5), (-0.16, -0.26), (0.16, -0.26), (0.24, -0.5), (0.5, -0.5), (0.13, 0.5),
           (-0.13, 0.5)]
A_HOLE = [(-0.09, -0.06), (0.09, -0.06), (0.0, 0.2)]


def _block():
    """A blue alphabet block teetering on the front rim: cream panels, a red 'A' with an ink rim."""
    out = []
    s = 1.2
    c = Vector((-0.75, -BD / 2 + 0.55, RIM + 0.5))
    rot = (0.35, -0.2, 0.45)
    bm_ = M(c, rot)
    body = K.rounded_box(BLOCK, (s, s, s), bm_, bevel=0.12, segments=2, name="block")
    inv3 = bm_.to_3x3().inverted()
    pal = []
    for f in body.mesh.polygons:
        q = inv3 @ Vector(f.normal)
        h = max(abs(q.x), abs(q.y))
        pal.append(BLOCK_L if q.z > h + 1e-4 else (BLOCK_D if -q.z > h + 1e-4 else BLOCK))
    body.face_pal = pal
    out.append(body)
    # panels on the faces + the letter on the front and top faces
    faces = [((0, -1, 0), (1, 0, 0), True), ((0, 0, 1), (1, 0, 0), True), ((-1, 0, 0), (0, -1, 0), True),
             ((1, 0, 0), (0, 1, 0), False), ((0, 1, 0), (-1, 0, 0), False)]
    for n, u, letter in faces:
        n, u = Vector(n), Vector(u)
        v = Vector((0, 0, 1)) if n.z == 0 else Vector((0, 1, 0))  # letter up
        fm = bm_ @ Matrix(((u.x, v.x, n.x, n.x * s / 2), (u.y, v.y, n.y, n.y * s / 2), (u.z, v.z, n.z, n.z * s / 2),
                           (0, 0, 0, 1)))
        panel = K.rounded_box(PANEL, (s * 0.74, s * 0.74, 0.04), fm @ M((0, 0, 0.005)), bevel=0.015, segments=1,
                              outline=False, name="panel")
        out.append(_flat(panel))
        if letter:
            ls = s * 0.56
            sc = Matrix.Diagonal(Vector((ls, ls, 1, 1)))
            rim = [_offset(A_OUTER, 0.06), _offset(A_HOLE, -0.06)]
            out.append(_decal(rim, fm @ Matrix.Translation((0, 0, 0.03)) @ sc, LETTER_INK, "letter_ink"))
            out.append(_decal([A_OUTER, A_HOLE], fm @ Matrix.Translation((0, 0, 0.034)) @ sc, LETTER, "letter"))
    return out


def _frame_along(origin, direction, side_hint=(1, 0, 0)):
    """Matrix whose local +z runs along `direction` from `origin`, local x ~ side_hint."""
    z = Vector(direction).normalized()
    x = Vector(side_hint)
    x = (x - z * x.dot(z)).normalized()
    y = z.cross(x)
    o = Vector(origin)
    return Matrix(((x.x, y.x, z.x, o.x), (x.y, y.y, z.y, o.y), (x.z, y.z, z.z, o.z), (0, 0, 0, 1)))


def _sword():
    """A wooden toy sword, blade down in the pile, hilt poking out of the gap at the front left."""
    out = []
    tip = Vector((-2.9, -0.6, 2.25))
    hilt = Vector((-3.4, -2.2, 5.72))
    m = _frame_along(tip, hilt - tip, (1, 0, 0.3))
    L = (hilt - tip).length
    bl = L - 1.05  # blade length (the hilt takes the rest)
    w = 0.27
    blade = [(0, 0), (w, 0.38), (w, bl), (-w, bl), (-w, 0.38)]
    # local frame: blade outline in x/z, thickness along y -> map the 2D loop's y to local z
    flat_to_local = Matrix(((1, 0, 0, 0), (0, 0, -1, -0.07), (0, 1, 0, 0), (0, 0, 0, 1)))
    b = _prism(blade, 0.14, m @ flat_to_local, BLADE, chamfer=0.04, name="blade")
    _tone(b, BLADE, BLADE_L, BLADE_D, up=0.5, down=-0.5)
    out.append(b)
    out.append(_box(GUARD, (1.35, 0.34, 0.3), m @ M((0, 0, bl + 0.12)), 0.08, 2, "guard"))
    out.append(K.cylinder(GRIP, radius=0.14, depth=0.72, mat=m @ M((0, 0, bl + 0.6)), seg=10, name="grip"))
    out.append(K.sphere(POMMEL, 0.22, m @ M((0, 0, bl + 1.02)), seg=10, rings=6, name="pommel"))
    return out


def _pile():
    """Toys heaped inside (only their tops show): lumpy rounded shapes in toy colours."""
    out = []
    lumps = [(-3.2, 0.6, 1.2, 0.9, 0.0), (-1.3, 0.9, 1.1, 1.0, 0.6), (0.6, 0.5, 1.2, 0.9, 1.1),
             (2.9, 0.4, 1.2, 1.0, 0.3), (-2.4, -0.9, 1.0, 0.8, 1.4), (3.2, -0.9, 0.9, 0.8, 0.9),
             (0.2, -1.0, 1.0, 0.8, 0.2)]
    for i, (x, y, rx, ry, rz) in enumerate(lumps):
        col = PILE[i % len(PILE)]
        out.append(K.sphere(col, 1.0, M((x, y, RIM - 0.3), (0, 0, rz), (rx, ry, 0.55)), seg=10, rings=6, name="pile"))
    return out


def _sock():
    """Orange striped sock over the front rim, dangling down the front, its foot turned left."""
    x = 3.0
    yb = -BD / 2 + WALL       # inner face of the front wall
    yo = -BD / 2 - TRIM - 0.16  # just in front of the top band
    t = 0.13
    over = RIM + 0.06 + t + 0.03
    UP, FRONT = (0, 0, 1), (0, -1, 0)
    ctrl = [(x - 0.35, yb + 1.3, RIM + 0.25), (x - 0.15, yb + 0.5, RIM + 0.3), (x - 0.03, yb - 0.25, over),
            (x, yo + 0.04, RIM - 0.15), (x + 0.03, yo, RIM - 0.9), (x + 0.02, yo + 0.02, 1.75),
            (x - 0.1, yo + 0.04, 1.1), (x - 0.8, yo + 0.04, 0.98), (x - 1.55, yo + 0.04, 1.08)]
    hints = [UP, UP, (0, -0.4, 1), (0, -1, 0.3), FRONT, FRONT, FRONT, FRONT, FRONT]
    return [sock(ctrl, hints, dict(body=SOCK_O, stripe=SOCK_CR, accent=SOCK_OD, inner=SOCK_IN), heel=6, stripe=0.3,
                 width=0.4, toe=0.36, name="sock")]


# ---------------------------------------------------------------- build
def build():
    p = [_shell()]
    p += _trims()
    p += _star()
    p += _lid()
    p += _pile()
    p += _ball()
    p += _block()
    p += _sword()
    p += _sock()
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    _no_bounce(outline)
    return [body, outline] + K.markers(NAME)
