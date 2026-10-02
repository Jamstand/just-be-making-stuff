"""
props/dresser.py - the Dresser prop (ReplicatedStorage.MapMeshes.Dresser): a big chest of drawers against
the south wall of the expanded bedroom. See props/__init__.py for the conventions every prop follows.

Built in the style of the concept's dressers (docs/concept/bedroom_keyframe.png, left and right edges):
warm orange-brown wood, a chunky top slab with flat 45-degree chamfers that overhangs the body, thick
drawer fronts with a chamfered border and chunky chamfered block handles, short tapered block feet,
lit top edges, darker undersides and a dark ink gap round every drawer (thin dark plates behind the
drawer fronts and handles - the inverted hull alone can't draw a line round a part seen head-on).
Layout: three rows - two small drawers side by side on top, two wide drawers below. The middle drawer
is pulled out a little (plum-brown box sides, blue liner, a dark opening behind it) with socks spilling
over its front edge: the drawer is stuffed with a lumpy pile of socks, a red / cream striped sock dangles
down the front (its foot kicks sideways at the bottom), a lavender sock's foot flops over the right end, a
green sock hangs cuff-down at the left and a rolled-up blue pair peeks over the edge. On top: a framed
picture on a little easel (sky, hill, sun), two books and a little cactus in a blue pot.

Units: 1 unit = 10 studs. Map.luau scales the prop uniformly so its visible bounds fit 130 x 110 x 60
studs (W x H x D), so the whole thing - pulled drawer, handles, socks and the decor on top included - is
13.0 x 11.0 x 6.0 units: the slab top is at 9.0 and the decor stays under ~2 units. Origin = floor centre
under the body, front faces -Y.

`sweep()` / `sock()` are also used by props/toychest.py (the sock hanging over its rim).
"""
import math
import bmesh
import bpy
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol

NAME = "Dresser"

# ---- colours: wood sampled from the concept's dressers (lit fronts #C25C34-#C4673A, lit top #E8914A,
# open-drawer box sides #572A2F-#5A2B31, inside #3E171A, liner #526E9D)
WOOD = hexcol("dresser_wood", "#C4633A")          # fronts, sides
WOOD_L = hexcol("dresser_wood_light", "#E8914A")  # top-facing faces and top chamfers
WOOD_D = hexcol("dresser_wood_dark", "#8A3E2A")   # undersides, bottom chamfers
BOX = hexcol("dresser_box", "#5C2C32")            # outside of the pulled drawer's box (cool plum)
BOX_RIM = hexcol("dresser_box_rim", "#B5613A")    # flat tops of the box walls
INSIDE = hexcol("dresser_inside", "#40181B")      # inside faces of the drawer
HOLE = hexcol("dresser_hole", "#2A1216")          # the dark opening behind the pulled drawer
LINER = hexcol("dresser_liner", "#5674AA")        # blue liner paper
INK = K.OUTLINE
# socks (concept clothesline palette: red, lavender, green)
SK_RED = hexcol("dresser_sock_red", "#E4504E")
SK_RED_D = hexcol("dresser_sock_red_dark", "#B8343E")
SK_CREAM = hexcol("dresser_sock_cream", "#FFF0D8")
SK_LAV = hexcol("dresser_sock_lavender", "#B88AE6")
SK_LAV_D = hexcol("dresser_sock_lavender_dark", "#8455C4")
SK_GRN = hexcol("dresser_sock_green", "#6CCB5A")
SK_GRN_D = hexcol("dresser_sock_green_dark", "#3F9A44")
SK_YEL = hexcol("dresser_sock_yellow", "#FFD24A")
SK_BLUE = hexcol("dresser_sock_blue", "#7FB4EE")
SK_BLUE_D = hexcol("dresser_sock_blue_dark", "#4F86D0")
SK_BLUE_L = hexcol("dresser_sock_blue_light", "#A9CFF6")
SK_IN = hexcol("dresser_sock_inner", "#3A2F4E")   # the sock opening
# top decor
FRAME = hexcol("dresser_frame", "#F2C14E")
FRAME_L = hexcol("dresser_frame_light", "#FFDA7A")
FRAME_D = hexcol("dresser_frame_dark", "#C9922E")
SKY = hexcol("dresser_pic_sky", "#8FD3F7")
HILL = hexcol("dresser_pic_hill", "#6CC46A")
HILL_D = hexcol("dresser_pic_hill_dark", "#4FA554")
SUN = hexcol("dresser_pic_sun", "#FFD23F")
POT = hexcol("dresser_pot", "#5B8FDB")
POT_L = hexcol("dresser_pot_light", "#7FAAEC")
POT_D = hexcol("dresser_pot_dark", "#3F6BB5")
SOIL = hexcol("dresser_soil", "#4A2B22")
CACTUS = hexcol("dresser_cactus", "#5DB24F")
CACTUS_L = hexcol("dresser_cactus_light", "#7ECB61")
CACTUS_D = hexcol("dresser_cactus_dark", "#3E8C3D")
FLOWER = hexcol("dresser_flower", "#F27A9E")
FLOWER_C = hexcol("dresser_flower_centre", "#FFD23F")
BOOK_R = hexcol("dresser_book_red", "#D9473F")
BOOK_R_L = hexcol("dresser_book_red_light", "#F06A58")
BOOK_R_D = hexcol("dresser_book_red_dark", "#A8302E")
BOOK_B = hexcol("dresser_book_blue", "#4F7FD6")
BOOK_B_L = hexcol("dresser_book_blue_light", "#78A0EA")
BOOK_B_D = hexcol("dresser_book_blue_dark", "#3A5EAA")
PAGES = hexcol("dresser_book_pages", "#FFF4DC")

# ---- dimensions (units)
H = 9.0                         # top of the slab (the decor on it reaches ~11)
TOP_W, TOP_T = 13.0, 1.15
TOP_Y0, TOP_Y1 = -2.05, 2.2     # slab front / back (overhangs the body front by 0.5)
BODY_W = 12.2
BODY_Y0, BODY_Y1 = -1.55, 2.1   # body front / back
FOOT_H = 0.6
BODY_Z0, BODY_Z1 = FOOT_H, H - TOP_T + 0.05
FT = 0.42                       # drawer front thickness
FB = 0.21                       # drawer front chamfer
GAP = 0.07                      # ink margin round a drawer front
ROW_W = 11.4                    # drawer row width (0.4 stiles left and right)
SMALL_W = (ROW_W - 0.3) / 2     # top row: two drawers with a 0.3 divider
ROWS = [(5.89, 7.6), (3.47, 5.61), (1.05, 3.19)]  # (z0, z1): top row, middle (pulled), bottom
PULL = 1.25                     # how far the middle drawer is pulled out
HW, HH, HD, HB = 1.6, 0.72, 0.48, 0.16  # handle width / height / protrusion / chamfer
HANDLE_X = 3.2                  # wide drawers: two handles at +-HANDLE_X
OUTLINE_W = 0.14                # ~1.3% of the overall height


# ---------------------------------------------------------------- helpers
def _tone(piece, base=WOOD, light=WOOD_L, dark=WOOD_D, up=0.6, down=-0.6):
    """2-3 tone paint: faces looking up get the light tone, faces looking down the dark one."""
    piece.face_pal = [light if f.normal.z > up else (dark if f.normal.z < down else base) for f in piece.mesh.polygons]
    return piece


def _flat(piece):
    piece.smooth = False
    return piece


def _flat_big_faces(piece, min_area):
    """Large flat faces shade flat (no smooth-shading smears); small bevel faces stay smooth."""
    piece.flat_faces = [i for i, f in enumerate(piece.mesh.polygons) if f.area >= min_area]
    return piece


def _chamfer(pal, size, loc, chamfer, name, taper=None, rot=(0, 0, 0)):
    """A box with flat 45-degree chamfered edges (optionally narrower at the bottom), flat shaded."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    if taper:
        for v in bm.verts:
            if v.co.z < 0:
                v.co.x *= taper[0]
                v.co.y *= taper[1]
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    K.link(obj)
    obj.matrix_world = M(loc, rot)
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = chamfer
    mod.segments = 1
    mod.limit_method = "ANGLE"
    mod.harden_normals = False
    return K.Piece(K.bake_object(obj), pal, outline=True, smooth=False, name=name)


def _plate(size, loc, pal=INK, name="gap"):
    """A dark slab just proud of a face, a little bigger than the part in front of it: the ink line
    drawn round a drawer front / handle, seen from every angle."""
    return K.Piece(K.rounded_box(pal, size, M(loc), bevel=0.03, segments=1).mesh, pal, outline=False,
                   smooth=False, name=name)


def _no_bounce(outline):
    """Preview only (Cycles ray flags, not exported): the inverted hull must not block bounce light."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False


# ---------------------------------------------------------------- sweeps (socks, cactus)
def _catmull(ctrl, n=24):
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


def sweep(ctrl, hints, width, thick, step=0.1, sides=12, tip=True, squash=2.6, heel=None, heel_bump=0.0,
          bulge=None):
    """A flattened tube along a smooth curve through `ctrl`.

    hints[i] = the "lying on" normal at ctrl[i] (the thin axis of the section); the wide axis is
    across the path in that surface. width / thick are half sizes; the section is a superellipse
    (exponent `squash`). The start is closed with a flat cap, the end with a rounded tip (tip=True:
    a half-ellipsoid as long as the half width) or a flat cap. `heel` = control index of a bend: the
    tube bulges out by heel_bump on the outside of that bend. `bulge(s_len) -> scale` widens the tube
    along its length (s_len = distance from the start).
    -> (mesh, info): info[i] = (kind "side"|"cap"|"tip", row, k, s_len, heel_weight) for face i,
    heel_weight in 0..1 = how much the face is on the heel patch; also returns the length."""
    ctrl = [Vector(c) for c in ctrl]
    dense = _catmull(ctrl)
    lens = [0.0]
    for i in range(1, len(dense)):
        lens.append(lens[-1] + (dense[i][0] - dense[i - 1][0]).length)
    L = lens[-1]
    rows = max(2, int(round(L / step)))

    def at(d):
        """point + fractional ctrl index at arc length d."""
        d = max(0.0, min(L, d))
        lo, hi = 0, len(lens) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if lens[mid] <= d:
                lo = mid
            else:
                hi = mid
        seg = lens[hi] - lens[lo]
        u = (d - lens[lo]) / seg if seg > 1e-9 else 0.0
        return dense[lo][0].lerp(dense[hi][0], u), dense[lo][1] + (dense[hi][1] - dense[lo][1]) * u

    def hint_at(fi):
        i0 = min(int(math.floor(fi)), len(hints) - 1)
        i1 = min(i0 + 1, len(hints) - 1)
        h = Vector(hints[i0]).normalized().lerp(Vector(hints[i1]).normalized(), fi - i0)
        return h.normalized()

    def tangent(d):
        e = max(step * 0.5, 0.02)
        return (at(d + e)[0] - at(d - e)[0]).normalized()

    tip_len = width if tip else 0.0
    body_len = L - tip_len
    # rings: evenly along the body, then a few rings closing the rounded tip
    ds = [body_len * r / rows for r in range(rows + 1)]
    if tip:
        nt = 4
        ds += [body_len + tip_len * math.sin((j / (nt + 1)) * math.pi / 2) for j in range(1, nt + 1)]
    heel_d = None
    if heel is not None:
        best = min(range(len(dense)), key=lambda i: abs(dense[i][1] - heel))
        heel_d = lens[best]
        tb, ta = tangent(heel_d - width * 1.2), tangent(heel_d + width * 1.2)
        heel_out = (tb - ta).normalized()
    bm = bmesh.new()
    rings, ring_d = [], []
    for d in ds:
        p, fi = at(d)
        T = tangent(d)
        Hn = hint_at(fi)
        Wd = T.cross(Hn)
        if Wd.length < 1e-6:
            Wd = T.orthogonal()
        Wd.normalize()
        Nn = Wd.cross(T).normalized()
        sc = 1.0
        if d > body_len:
            u = (d - body_len) / tip_len
            sc = math.sqrt(max(0.0, 1 - u * u))
        if bulge:
            sc *= bulge(d)
        # the inside of a tight bend is squashed flat (like bunched fabric) instead of folding through
        # itself: no vertex reaches further toward the bend centre than 0.8 of the bend radius
        e = max(width * 0.5, step)
        kv = (tangent(min(d + e, L)) - tangent(max(d - e, 0.0))) / (2 * e)
        bend = (kv.normalized(), 0.8 / kv.length) if kv.length > 1e-3 else None
        ring = []
        for k in range(sides):
            a = (k + 0.5) / sides * math.tau
            c, s = math.cos(a), math.sin(a)
            c2 = math.copysign(abs(c) ** (2 / squash), c)
            s2 = math.copysign(abs(s) ** (2 / squash), s)
            off = Wd * (c2 * width * sc) + Nn * (s2 * thick * sc)
            if heel_d is not None and heel_bump:
                g = math.exp(-((d - heel_d) / (width * 0.9)) ** 2)
                dirn = off.normalized() if off.length > 1e-9 else off
                w = max(0.0, dirn.dot(heel_out))
                off = off + dirn * (heel_bump * g * w ** 1.5)
            if bend is not None:
                inward = off.dot(bend[0])
                if inward > bend[1]:
                    off = off - bend[0] * (inward - bend[1])
            ring.append(bm.verts.new(p + off))
        rings.append(ring)
        ring_d.append(d)
    info = []
    for r in range(len(rings) - 1):
        for k in range(sides):
            k2 = (k + 1) % sides
            bm.faces.new((rings[r][k], rings[r][k2], rings[r + 1][k2], rings[r + 1][k]))
            dm = (ring_d[r] + ring_d[r + 1]) / 2
            hw = 0.0
            if heel_d is not None:
                pc = sum((v.co for v in (rings[r][k], rings[r][k2], rings[r + 1][k2], rings[r + 1][k])), Vector()) / 4
                cen = (at(ring_d[r])[0] + at(ring_d[r + 1])[0]) / 2
                dirn = (pc - cen).normalized()
                hw = max(0.0, dirn.dot(heel_out)) if abs(dm - heel_d) < width * 0.85 else 0.0
            info.append(("side", r, k, dm, hw))
    bm.faces.new(list(reversed(rings[0])))
    info.append(("cap", 0, 0, 0.0, 0.0))
    if tip:
        pole = bm.verts.new(at(L)[0])
        last = rings[-1]
        for k in range(sides):
            bm.faces.new((last[k], last[(k + 1) % sides], pole))
            info.append(("tip", len(rings) - 1, k, L, 0.0))
    else:
        bm.faces.new(rings[-1])
        info.append(("cap", len(rings) - 1, 0, L, 0.0))
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("sweep")
    bm.to_mesh(me)
    bm.free()
    return me, info, L


def sock(ctrl, hints, cols, width=0.42, thick=0.13, heel=None, stripe=0.0, cuff=0.45, toe=0.42,
         name="sock", step=0.15, sides=10):
    """A flat-lying sock along ctrl (cuff at the start, toe at the end, heel at control index `heel`).
    cols = dict(body, accent, inner[, stripe]): accent colours the ribbed cuff band, heel patch and toe;
    `stripe` > 0 paints bands of cols["stripe"] about that long down the leg and foot. Bands are whole
    rows of the sweep (snapped to its ring spacing), so every stripe is equally wide and edges are clean."""
    def bulge(d):  # the ribbed cuff band stands a little proud of the leg
        return 1.07 if d < cuff else 1.0
    me, info, L = sweep(ctrl, hints, width, thick, step=step, sides=sides, heel=heel, heel_bump=width * 0.28,
                        bulge=bulge)
    mids = sorted({d for kind, r, k, d, hw in info if kind == "side"})
    row = mids[1] - mids[0]
    cuff_end = max(1, round(cuff / row)) * row
    band = max(1, round(stripe / row)) * row if stripe else 0.0
    pal = []
    flat = []
    for i, (kind, r, k, d, hw) in enumerate(info):
        if kind == "cap":
            pal.append(cols["inner"])
            flat.append(i)
        elif kind == "tip" or d > L - toe or d < cuff_end or hw > 0.2:
            pal.append(cols["accent"])
        elif band and int((d - cuff_end) / band) % 2 == 0:
            pal.append(cols["stripe"])
        else:
            pal.append(cols["body"])
    p = K.Piece(me, pal, outline=True, smooth=True, name=name)
    p.flat_faces = flat
    return p


# ---------------------------------------------------------------- dresser parts
def _handle(x, z, y_face):
    """Chunky chamfered block handle on a drawer face at y_face, with its ink plate."""
    out = [_plate((HW + 0.14, 0.08, HH + 0.14), (x, y_face - 0.02, z), name="handle_gap")]
    h = _chamfer(WOOD, (HW, HD + 0.06, HH), (x, y_face - 0.04 - HD / 2, z), HB, "handle")
    out.append(_tone(h))
    return out


def _closed_drawer(x, w, z0, z1, handles):
    """A drawer front sitting on its dark gap plate on the body front."""
    zc, h = (z0 + z1) / 2, z1 - z0
    out = [_plate((w + 2 * GAP, 0.1, h + 2 * GAP), (x, BODY_Y0 - 0.02, zc), name="drawer_gap")]
    y_back = BODY_Y0 - 0.04
    board = _chamfer(WOOD, (w, FT, h), (x, y_back - FT / 2, zc), FB, "front")
    out.append(_tone(board))
    for hx in handles:
        out += _handle(hx, zc, y_back - FT)
    return out


def _pulled_drawer(z0, z1):
    """The middle drawer pulled out by PULL: dark opening, plum box with lit rims, blue liner, front."""
    w, h, zc = ROW_W, z1 - z0, (z0 + z1) / 2
    out = [_plate((w + 2 * GAP, 0.1, h + 2 * GAP), (0, BODY_Y0 - 0.02, zc), pal=HOLE, name="opening")]
    y_back = BODY_Y0 - 0.04 - PULL      # back face of the front board
    yf = y_back - FT
    bx = w / 2 - 0.32                   # box outer half width
    bz0, bz1 = z0 + 0.12, z1 - 0.42     # box bottom / wall tops
    by1 = BODY_Y0 + 0.5                 # box runs on into the body (hidden)
    wall = 0.22
    by0 = y_back + 0.02

    def box_paint(piece, inward_x):
        pal = []
        for f in piece.mesh.polygons:
            n = f.normal
            if n.z > 0.6:
                pal.append(BOX_RIM)
            elif n.z < -0.6:
                pal.append(WOOD_D)
            elif inward_x and n.x * f.center.x < -0.3:
                pal.append(INSIDE)
            else:
                pal.append(BOX)
        piece.face_pal = pal
        return piece

    for sx in (-1, 1):
        loc = (sx * (bx - wall / 2), (by0 + by1) / 2, (bz0 + bz1) / 2)
        side = K.rounded_box(BOX, (wall, by1 - by0, bz1 - bz0), M(loc),
                             bevel=0.06, segments=1, name="box_side")
        out.append(_flat(box_paint(side, True)))
    bottom = K.rounded_box(BOX, (2 * bx, by1 - by0, 0.2), M((0, (by0 + by1) / 2, bz0 + 0.1)), bevel=0.05, segments=1,
                           name="box_bottom")
    out.append(_flat(box_paint(bottom, False)))
    liner = K.rounded_box(LINER, (2 * (bx - wall) - 0.02, by1 - by0 - 0.05, 0.12),
                          M((0, (by0 + by1) / 2, bz0 + 0.26)), bevel=0.03, segments=1, name="liner")
    out.append(K.Piece(liner.mesh, LINER, outline=False, smooth=False, name="liner"))
    # front board: its inside face is the dark inside wood
    board = _chamfer(WOOD, (w, FT, h), (0, y_back - FT / 2, zc), FB, "front")
    pal = []
    for f in board.mesh.polygons:
        n = f.normal
        pal.append(WOOD_L if n.z > 0.6 else (WOOD_D if n.z < -0.6 else (INSIDE if n.y > 0.9 else WOOD)))
    board.face_pal = pal
    out.append(board)
    for hx in (-HANDLE_X, HANDLE_X):
        out += _handle(hx, zc, yf)
    return out, dict(y_back=y_back, yf=yf, top=z1, bottom=z0, floor=bz0 + 0.32, bx=bx)


def _socks(d):
    """Socks spilling out of the pulled drawer (d = its key positions)."""
    top, yf, yb = d["top"], d["yf"], d["y_back"]
    out = []
    t = 0.13
    over = top + t + 0.03            # path height crossing the board's top edge
    yo = yf - t - 0.03               # path just in front of the board's front face
    UP, FRONT = (0, 0, 1), (0, -1, 0)
    # 1) red / cream striped sock: leg lying on the pile, over the edge, dangling down the front, heel at
    #    the bottom and the foot kicking out to the right along the board
    x = -1.35
    ctrl = [(x + 0.5, yb + 1.3, top - 0.2), (x + 0.2, yb + 0.45, top - 0.02), (x + 0.05, yb - 0.2, over),
            (x, yf + 0.02, over - 0.02), (x - 0.02, yo, top - 0.32), (x - 0.06, yo, top - 0.95),
            (x - 0.05, yo, d["bottom"] + 0.6), (x + 0.15, yo - 0.02, d["bottom"] + 0.12),
            (x + 0.85, yo - 0.03, d["bottom"] - 0.02), (x + 1.45, yo - 0.02, d["bottom"] + 0.12)]
    hints = [UP, UP, (0, -0.3, 1), (0, -1, 0.6), FRONT, FRONT, FRONT, FRONT, FRONT, FRONT]
    out.append(sock(ctrl, hints, dict(body=SK_RED, stripe=SK_CREAM, accent=SK_RED_D, inner=SK_IN),
                    heel=7, stripe=0.3, name="sock_striped"))
    # 2) lavender sock lying on the pile, heel on the edge, its foot flopping down the front
    x = 4.85
    ctrl = [(x - 0.6, yb + 1.5, top - 0.12), (x - 0.3, yb + 0.6, top + 0.02), (x - 0.08, yb - 0.25, over + 0.02),
            (x - 0.02, yo + 0.04, top - 0.3), (x + 0.02, yo, top - 0.9), (x - 0.04, yo + 0.01, top - 1.45)]
    hints = [UP, UP, (0, -0.4, 1), (0, -1, 0.3), FRONT, FRONT]
    out.append(sock(ctrl, hints, dict(body=SK_LAV, accent=SK_LAV_D, inner=SK_IN), heel=2, toe=0.5,
                    name="sock_lavender"))
    # 3) green sock: foot lying on the pile, leg hanging over the edge, open cuff at the bottom
    x = -4.85
    ctrl = [(x + 0.04, yo + 0.01, top - 1.25), (x, yo, top - 0.7), (x - 0.02, yo + 0.04, top - 0.25),
            (x - 0.05, yb - 0.25, over + 0.02), (x - 0.02, yb + 0.55, top + 0.02), (x + 0.05, yb + 1.05, top - 0.02),
            (x + 0.7, yb + 1.3, top - 0.1)]
    hints = [FRONT, FRONT, (0, -1, 0.3), (0, -0.4, 1), UP, UP, UP]
    out.append(sock(ctrl, hints, dict(body=SK_GRN, accent=SK_YEL, inner=SK_IN), heel=5, toe=0.4,
                    name="sock_green"))
    # 4) a rolled-up pair on the pile, peeking over the front edge
    out += _sock_ball((1.45, yb + 0.62, top + 0.2), 0.6, 0.35, SK_BLUE, SK_BLUE_D, SK_BLUE_L)
    # the drawer is stuffed: a lumpy pile of socks fills it up to just under the front edge
    for x, y, rx, ry, col in ((-4.0, yb + 1.0, 1.3, 0.9, SK_LAV), (-2.2, yb + 0.9, 1.1, 0.8, SK_BLUE),
                              (-0.3, yb + 1.0, 1.2, 0.9, SK_GRN), (1.6, yb + 1.05, 1.2, 0.85, SK_RED),
                              (3.5, yb + 0.95, 1.2, 0.9, SK_YEL), (-1.2, yb + 1.9, 1.6, 0.8, SK_LAV),
                              (2.4, yb + 1.9, 1.6, 0.8, SK_BLUE)):
        out.append(K.sphere(col, 1.0, M((x, y, top - 0.38), (0, 0, 0.3 * x), (rx, ry, 0.42)), seg=10, rings=6,
                            name="pile"))
    return out


def _sock_ball(c, r, rot, body, accent, light):
    """A rolled-up pair of socks: a squashed ball with the folded-over, ribbed cuff band round it."""
    ball = K.sphere(body, r, M(c, (0.3, 0.0, rot), (1.15, 1.0, 0.86)), seg=14, rings=9, name="sock_ball")
    band = K.cylinder(accent, radius=r * 1.06, depth=r * 0.85, mat=M(c, (0.3, 0.0, rot), (1.15, 1.0, 0.86)), seg=16,
                      name="sock_band")
    # ribs: alternate side faces light / accent; the cap rings stay accent
    band.face_pal = [accent if len(f.vertices) > 4 else (light if i % 2 else accent)
                     for i, f in enumerate(band.mesh.polygons)]
    return [ball, band]


# ---------------------------------------------------------------- top decor
def _flat_disc(center, normal, radius, pal, seg=16, rx=None, start=0.0, end=math.tau, name="disc"):
    """A flat (half) disc / ellipse facing `normal`, centred on `center`; no outline."""
    n = Vector(normal).normalized()
    u = Vector((1, 0, 0)) if abs(n.x) < 0.9 else Vector((0, 1, 0))
    u = (u - n * u.dot(n)).normalized()
    v = n.cross(u)
    verts = []
    full = abs(end - start - math.tau) < 1e-6
    count = seg if full else seg + 1
    for k in range(count):
        a = start + (end - start) * k / (seg if not full else seg)
        verts.append(Vector(center) + u * math.cos(a) * (rx or radius) + v * math.sin(a) * radius)
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(p) for p in verts], [], [list(range(len(verts)))])
    me.update()
    bm = bmesh.new()
    bm.from_mesh(me)
    for f in bm.faces:
        if f.normal.dot(n) < 0:
            f.normal_flip()
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pal, outline=False, smooth=False, name=name)


def _picture(cx, cy):
    """A chunky yellow frame on a little easel, leaning back, with a sky / hill / sun picture."""
    out = []
    tilt = -0.2
    fw, fh, fd, bar = 2.2, 2.7, 0.3, 0.38
    zb = H + 0.02

    def L(x, y, z):  # frame-local (x across, y out of the back, z up from the bottom edge) -> world
        m = M((cx, cy, zb), (tilt, 0, 0))
        return m @ Vector((x, y, z))

    def piece(pal, size, loc, bevel, name, light=None, dark=None):
        p = K.rounded_box(pal, size, M(L(*loc), (tilt, 0, 0)), bevel=bevel, segments=1, name=name)
        if light is not None:
            _tone(p, pal, light, dark, up=0.55, down=-0.55)
        return _flat_big_faces(p, 0.12)

    # backing board, then four chunky bars
    out.append(piece(FRAME, (fw - 0.2, fd * 0.6, fh - 0.2), (0, 0.05, fh / 2), 0.05, "frame_back", FRAME_L, FRAME_D))
    for x in (-(fw - bar) / 2, (fw - bar) / 2):
        out.append(piece(FRAME, (bar, fd, fh), (x, 0, fh / 2), 0.11, "frame_bar", FRAME_L, FRAME_D))
    for z in (bar / 2, fh - bar / 2):
        out.append(piece(FRAME, (fw - 2 * bar + 0.1, fd, bar), (0, 0, z), 0.11, "frame_bar", FRAME_L, FRAME_D))
    # the picture (flat, just in front of the backing board)
    yp = -fd * 0.3 + 0.08 - 0.12
    pw, ph = fw - 2 * bar, fh - 2 * bar
    nrm = (M((0, 0, 0), (tilt, 0, 0)).to_3x3() @ Vector((0, -1, 0))).normalized()
    sky = K.rounded_box(SKY, (pw + 0.02, 0.04, ph + 0.02), M(L(0, yp + 0.02, fh / 2), (tilt, 0, 0)), bevel=0.01,
                        segments=1, name="sky")
    out.append(K.Piece(sky.mesh, SKY, outline=False, smooth=False, name="sky"))
    out.append(_flat_disc(L(0.25, yp - 0.01, bar + 0.02), nrm, 0.62, HILL, seg=12, rx=0.95, start=0.0, end=math.pi,
                          name="hill"))
    out.append(_flat_disc(L(-0.45, yp - 0.015, bar + 0.02), nrm, 0.42, HILL_D, seg=10, rx=0.55, start=0.0,
                          end=math.pi, name="hill2"))
    out.append(_flat_disc(L(-0.3, yp - 0.01, fh - bar - 0.42), nrm, 0.24, SUN, seg=12, name="sun"))
    # easel leg behind
    leg = K.rounded_box(FRAME_D, (0.32, 0.18, 2.0), M((cx, cy + 0.85, zb + 0.95), (0.42, 0, 0)), bevel=0.06,
                        segments=1, name="easel")
    out.append(_flat(leg))
    return out


def _cactus(cx, cy):
    """A chunky cactus with two arms and a pink flower in a blue pot."""
    out = []
    z0 = H
    ph = 1.15
    pot = K.cylinder(POT, radius=0.62, radius2=0.78, depth=ph, mat=M((cx, cy, z0 + ph / 2)), seg=16, name="pot")
    _tone(pot, POT, POT_L, POT_D)
    out.append(pot)
    rim = K.cylinder(POT, radius=0.9, depth=0.32, mat=M((cx, cy, z0 + ph + 0.06)), seg=16, name="pot_rim")
    _tone(rim, POT, POT_L, POT_D)
    out.append(rim)
    soil = K.cylinder(SOIL, radius=0.74, depth=0.1, mat=M((cx, cy, z0 + ph + 0.2)), seg=16, outline=False, name="soil")
    out.append(soil)

    def ribbed(me, info, light_every=2):
        pal = []
        for kind, r, k, d, hw in info:
            if kind == "cap":
                pal.append(CACTUS_D)
            else:
                pal.append(CACTUS_L if k % light_every == 0 else CACTUS)
        return pal

    zt = z0 + ph + 0.15
    trunk = [(cx, cy, zt - 0.3), (cx, cy, zt + 0.5), (cx + 0.02, cy, zt + 1.05), (cx, cy, zt + 1.5)]
    up = (0, -1, 0)
    me, info, _ = sweep(trunk, [up] * 4, 0.46, 0.46, step=0.3, sides=12, squash=2.0)
    p = K.Piece(me, ribbed(me, info), outline=True, smooth=True, name="cactus")
    out.append(_tone_dark_under(p))
    for sx, zj, reach, rise in ((-1, 0.5, 0.62, 0.7), (1, 0.8, 0.55, 0.5)):
        arm = [(cx, cy, zt + zj), (cx + sx * 0.55, cy, zt + zj - 0.05),
               (cx + sx * reach + sx * 0.1, cy, zt + zj + 0.25),
               (cx + sx * (reach + 0.12), cy, zt + zj + rise)]
        me, info, _ = sweep(arm, [up] * 4, 0.24, 0.24, step=0.17, sides=8, squash=2.0)
        p = K.Piece(me, ribbed(me, info), outline=True, smooth=True, name="arm")
        out.append(_tone_dark_under(p))
    # flower on top
    ft = zt + 1.5 - 0.02
    for k in range(5):
        a = k / 5 * math.tau
        out.append(K.sphere(FLOWER, 0.17, M((cx + math.cos(a) * 0.2, cy + math.sin(a) * 0.2, ft), scale=(1, 1, 0.6)),
                            seg=6, rings=4, outline=True, name="petal"))
    out.append(K.sphere(FLOWER_C, 0.13, M((cx, cy, ft + 0.06)), seg=6, rings=4, outline=False, name="flower_c"))
    return out


def _books(cx, cy):
    """Two chunky books lying flat, the top one a little turned: coloured covers, cream page block."""
    out = []
    z = H
    for (w, d, t, col, col_l, col_d, rot) in ((2.3, 1.6, 0.36, BOOK_R, BOOK_R_L, BOOK_R_D, 0.08),
                                             (2.0, 1.4, 0.3, BOOK_B, BOOK_B_L, BOOK_B_D, -0.22)):
        m = M((cx, cy, z + t / 2), (0, 0, rot))
        cover = K.rounded_box(col, (w, d, t), m, bevel=0.06, segments=1, name="book")
        out.append(_flat(_tone(cover, col, col_l, col_d)))
        pages = K.rounded_box(PAGES, (w - 0.12, d - 0.1, t - 0.12), m @ M((0.1, -0.06, 0)), bevel=0.02, segments=1,
                              outline=False, name="pages")
        out.append(_flat(pages))
        z += t
    return out


def _scaled(pieces, anchor, s):
    """Scales decor pieces (built at their natural size) by s about anchor."""
    a = Vector(anchor)
    m = Matrix.Translation(a) @ Matrix.Diagonal(Vector((s, s, s, 1.0))) @ Matrix.Translation(-a)
    for p in pieces:
        p.mesh.transform(m)
        p.mesh.update()
    return pieces


def _tone_dark_under(p):
    p.face_pal = [CACTUS_D if f.normal.z < -0.5 else p.face_pal[i] for i, f in enumerate(p.mesh.polygons)]
    return p


# ---------------------------------------------------------------- build
def build():
    p = []
    # top slab: chamfered all round, lit top + chamfer, dark underside
    slab = _chamfer(WOOD, (TOP_W, TOP_Y1 - TOP_Y0, TOP_T), (0, (TOP_Y0 + TOP_Y1) / 2, H - TOP_T / 2), 0.26, "top")
    p.append(_tone(slab))
    # body (carcass)
    body = K.rounded_box(WOOD, (BODY_W, BODY_Y1 - BODY_Y0, BODY_Z1 - BODY_Z0),
                         M((0, (BODY_Y0 + BODY_Y1) / 2, (BODY_Z0 + BODY_Z1) / 2)), bevel=0.14, segments=2, name="body")
    p.append(_flat_big_faces(_tone(body), 0.5))
    # raised panels on the body sides
    for sx in (-1, 1):
        panel = _chamfer(WOOD, (0.24, BODY_Y1 - BODY_Y0 - 1.0, BODY_Z1 - BODY_Z0 - 1.3),
                         (sx * BODY_W / 2, (BODY_Y0 + BODY_Y1) / 2, (BODY_Z0 + BODY_Z1) / 2 - 0.1), 0.09, "side_panel")
        p.append(_tone(panel))
    # feet: short, square, a touch narrower at the floor, set in from the corners
    fw = 1.15
    for x in (-(BODY_W / 2 - 0.25 - fw / 2), BODY_W / 2 - 0.25 - fw / 2):
        for y in (BODY_Y0 + 0.25 + fw / 2, BODY_Y1 - 0.25 - fw / 2):
            p.append(_tone(_chamfer(WOOD, (fw, fw, FOOT_H + 0.12), (x, y, (FOOT_H + 0.12) / 2), 0.12, "foot",
                                    taper=(0.84, 0.84))))
    # drawers: top row two small ones, a wide one pulled out, a wide one at the bottom
    z0, z1 = ROWS[0]
    for sx in (-1, 1):
        x = sx * (SMALL_W / 2 + 0.15)
        p += _closed_drawer(x, SMALL_W, z0, z1, [x])
    pulled, d = _pulled_drawer(*ROWS[1])
    p += pulled
    z0, z1 = ROWS[2]
    p += _closed_drawer(0, ROW_W, z0, z1, [-HANDLE_X, HANDLE_X])
    p += _socks(d)
    # on top: the framed picture (left) and the cactus (right)
    p += _scaled(_picture(-3.9, 0.45), (-3.9, 0.45, H), 0.72)
    p += _scaled(_cactus(4.1, 0.25), (4.1, 0.25, H), 0.68)
    p += _books(0.9, 0.35)
    body_obj, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    _no_bounce(outline)
    return [body_obj, outline] + K.markers(NAME)
