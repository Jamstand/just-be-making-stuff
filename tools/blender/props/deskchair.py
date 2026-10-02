"""
props/deskchair.py - the DeskChair prop (ReplicatedStorage.MapMeshes.DeskChair): a chunky wooden kid's chair
that stands in front of the Desk, facing it. See props/__init__.py for the conventions every prop follows.

Same furniture language as the desk / wardrobe / bed (docs/concept/bedroom_keyframe.png): warm orange-brown
wood in 2-3 flat tones and thick ink outlines.
- four fat round legs, splayed a little, with collar rings and bun feet, joined by round rungs (an H
  stretcher) and a seat apron;
- a thick seat board with a puffy blue cushion (superellipsoid pillow, a tuft button, ties round the back posts);
- two back posts leaning back a little, capped with collar rings and big ball finials like the bed's posts;
- a rounded, arched backrest board with a heart cut out of it (its inner rim painted pink, so the heart reads
  from the front and from behind - the room mostly sees the chair's back) and a round rail under it.

Units: 1 unit = 10 studs. Map.luau fits the prop into 80 x 140 x 80 studs (W x H x D), so the chair is about
8 x 14 x 8 units: seat cushion top at ~5.75 (the Desk's top is at 8.6 at the same scale), finials at 14.
Origin = floor centre under the seat, front (the seat's front edge) faces -Y; the backrest is at +Y.
"""
import math
import bmesh
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import M, hexcol
from props.dresser import sweep
from props.wardrobe import (tone, chamfer_box, lathe, shape, no_bounce, flat_big_faces, outward)

NAME = "DeskChair"

# ---- colours
WOOD = hexcol("deskchair_wood", "#C4633A")
WOOD_L = hexcol("deskchair_wood_light", "#E8914A")
WOOD_D = hexcol("deskchair_wood_dark", "#8A3E2A")
HEART = hexcol("deskchair_heart", "#F27A9E")
CUSH = hexcol("deskchair_cushion", "#5C7FD1")
CUSH_L = hexcol("deskchair_cushion_light", "#7FA0E8")
CUSH_D = hexcol("deskchair_cushion_dark", "#3F5BB0")
PIPING = hexcol("deskchair_piping", "#AFC6F4")

# ---- dimensions (units)
SEAT_Z0, SEAT_Z1 = 4.3, 4.92    # seat board
SEAT_X = 3.6                    # seat half width
SEAT_Y0, SEAT_Y1 = -3.45, 3.15  # seat front / back
LEG_X = 3.0                     # leg axes (at the seat)
FRONT_LEG_Y = -2.75
BACK_LEG_Y = 2.6
SPLAY = math.radians(4.5)       # legs lean out a little below the seat
LEG_R = 0.44
POST_TOP = 12.75                # top of the back posts (under the collar + ball)
LEAN = 0.85                     # how far the posts lean back between the seat and their top
BALL_R = 0.62
OUTLINE_W = 0.13                # same ink weight as the Desk / Wardrobe at the same scale


def _post_y(z):
    """y of the back posts' axis at height z (straight below the seat, leaning back above it)."""
    if z <= SEAT_Z1:
        return BACK_LEG_Y
    return BACK_LEG_Y + LEAN * ((z - SEAT_Z1) / (POST_TOP - SEAT_Z1)) ** 1.3


# ---------------------------------------------------------------- parts
def _front_leg(x, y):
    """A fat turned leg: bun foot, slightly tapered shaft, collar ring under the seat; splayed out."""
    r = LEG_R
    h = SEAT_Z0 + 0.05
    prof = [(0, 0), (r * 0.82, 0), (r * 1.02, 0.12), (r * 1.06, 0.3), (r * 0.88, 0.52), (r * 0.78, 0.66),
            (r * 0.86, h - 0.95), (r * 1.15, h - 0.82), (r * 1.15, h - 0.55), (r * 1.0, h - 0.45), (r * 1.0, h), (0, h)]
    sx = 1 if x > 0 else -1
    sy = 1 if y > 0 else -1
    # splay about the top centre: the foot moves out (x) and forward / back (y)
    m = M((x, y, h)) @ Matrix.Rotation(-sx * SPLAY, 4, "Y") @ Matrix.Rotation(sy * SPLAY, 4, "X") @ M((0, 0, -h))
    p = lathe(WOOD, prof, m, seg=12, name="leg")
    return tone(p, WOOD, WOOD_L, WOOD_D, up=0.55, down=-0.55)


def _foot_offset(z, sign):
    """How far a splayed leg's axis has moved out at height z (0 at the seat)."""
    return sign * math.tan(SPLAY) * (SEAT_Z0 - z)


def _back_post(x):
    """Back leg and post in one: splayed foot, straight to the seat, then leaning back to the top."""
    sx = 1 if x > 0 else -1
    zs = [0.2, 2.2, SEAT_Z0, SEAT_Z1 + 0.6, 7.6, 10.2, POST_TOP]
    ctrl = []
    for z in zs:
        dx = _foot_offset(z, sx) if z < SEAT_Z0 else 0.0
        dy = _foot_offset(z, 1) if z < SEAT_Z0 else 0.0
        ctrl.append((x + dx, _post_y(z) + dy, z))
    hints = [(0, -1, 0)] * len(ctrl)

    def bulge(d):  # a little thicker toward the floor, slim at the top
        return 1.05 - 0.13 * min(1.0, d / POST_TOP)
    me, info, L = sweep(ctrl, hints, LEG_R * 0.98, LEG_R * 0.98, step=0.75, sides=12, tip=False, squash=2.0, bulge=bulge)
    p = K.Piece(me, WOOD, outline=True, smooth=True, name="post")
    p.flat_faces = [i for i, inf in enumerate(info) if inf[0] == "cap"]
    out = [tone(p, WOOD, WOOD_L, WOOD_D, up=0.55, down=-0.55)]
    # bun foot, a collar under the seat, and the collar + big ball on top (like the bed's posts)
    fx, fy = x + _foot_offset(0.25, sx), _post_y(0) + _foot_offset(0.25, 1)
    foot = lathe(WOOD, [(0, 0), (LEG_R * 0.85, 0), (LEG_R * 1.08, 0.14), (LEG_R * 1.1, 0.32), (LEG_R * 0.9, 0.55),
                        (0, 0.55)], M((fx, fy, 0)), seg=12, name="post_foot")
    out.append(tone(foot, WOOD, WOOD_L, WOOD_D, up=0.55, down=-0.55))
    yt = _post_y(POST_TOP)
    collar = lathe(WOOD, [(0, 0), (LEG_R * 0.95, 0), (LEG_R * 1.3, 0.1), (LEG_R * 1.3, 0.34), (LEG_R * 0.95, 0.44),
                          (0, 0.44)], M((x, yt, POST_TOP - 0.12)), seg=12, name="post_collar")
    out.append(tone(collar, WOOD, WOOD_L, WOOD_D))
    bz = POST_TOP - 0.12 + 0.44 + BALL_R * 0.88 - 0.1
    ball = K.sphere(WOOD, BALL_R, M((x, yt, bz), scale=(1, 1, 0.88)), seg=12, rings=8, name="finial")
    out.append(tone(ball, WOOD, WOOD_L, WOOD_D, up=0.62, down=-0.7))
    return out


def _rung(a, b, r=0.2, name="rung"):
    a, b = Vector(a), Vector(b)
    d = b - a
    rot = d.normalized().to_track_quat("Z", "Y").to_matrix().to_4x4()
    p = K.cylinder(WOOD, r, d.length, Matrix.Translation((a + b) / 2) @ rot, seg=8, name=name)
    return tone(p, WOOD, WOOD_L, WOOD_D, up=0.5, down=-0.5)


def _frame():
    out = [_front_leg(sx * LEG_X, FRONT_LEG_Y) for sx in (-1, 1)]
    out += _back_post(-LEG_X) + _back_post(LEG_X)
    # H stretcher: a rung down each side, one across between them
    zr = 1.55
    for sx in (-1, 1):
        a = (sx * LEG_X + _foot_offset(zr, sx), FRONT_LEG_Y + _foot_offset(zr, -1), zr)
        b = (sx * LEG_X + _foot_offset(zr, sx), BACK_LEG_Y + _foot_offset(zr, 1), zr)
        out.append(_rung(a, b, 0.21))
    yc = (FRONT_LEG_Y + BACK_LEG_Y) / 2
    out.append(_rung((-LEG_X - 0.1, yc, zr), (LEG_X + 0.1, yc, zr), 0.19))
    # seat apron under the seat board (front, back, sides), set back from its edges
    az0 = SEAT_Z0 - 0.75
    t = 0.38
    for (cx, cy, w, d) in ((0, FRONT_LEG_Y, 2 * LEG_X, t), (0, BACK_LEG_Y, 2 * LEG_X, t),
                           (-LEG_X, (FRONT_LEG_Y + BACK_LEG_Y) / 2, t, BACK_LEG_Y - FRONT_LEG_Y),
                           (LEG_X, (FRONT_LEG_Y + BACK_LEG_Y) / 2, t, BACK_LEG_Y - FRONT_LEG_Y)):
        ap = chamfer_box(WOOD, (w, d, SEAT_Z0 - az0 + 0.02), M((cx, cy, (az0 + SEAT_Z0) / 2)), 0.08, "apron")
        out.append(tone(ap, WOOD, WOOD_L, WOOD_D))
    # seat board: thick, softly rounded, a lit top
    seat = K.rounded_box(WOOD, (2 * SEAT_X, SEAT_Y1 - SEAT_Y0, SEAT_Z1 - SEAT_Z0),
                         M((0, (SEAT_Y0 + SEAT_Y1) / 2, (SEAT_Z0 + SEAT_Z1) / 2)), bevel=0.22, segments=2, name="seat")
    out.append(flat_big_faces(tone(seat, WOOD, WOOD_L, WOOD_D), 0.5))
    return out


def _heart(cx, cy, s, n=10):
    """A chunky heart outline (two round lobes, a soft dip between them, straight sides to the point), s = half
    width; centred on (cx, cy)."""
    lx, ly, lr = 0.47 * s, 0.3 * s, 0.52 * s
    right = []
    for i in range(n + 1):  # round the right lobe, from the dip clockwise to its outer side
        a = math.radians(165 - 205 * i / n)
        right.append((lx + lr * math.cos(a), ly + lr * math.sin(a)))
    pts = [(0.0, 0.42 * s)] + right + [(0.0, -1.0 * s)] + [(-x, y) for x, y in reversed(right)]
    return [(cx + x, cy + y) for x, y in pts]


def _backrest():
    """The arched backrest board with a heart cut-out, between the leaning posts, and a round rail under it."""
    out = []
    z0 = 7.0                        # board bottom (on the post axis)
    lean = math.atan2(_post_y(POST_TOP) - _post_y(z0), POST_TOP - z0)
    w = 2 * LEG_X - 0.1             # edges sink into the posts
    hh = 4.7                        # height at the posts
    peak = 6.05                     # height in the middle
    outer = [(-w / 2, 0.0), (w / 2, 0.0)]
    n = 14
    for i in range(n + 1):
        a = i / n * math.pi
        outer.append((w / 2 * math.cos(a), hh + (peak - hh) * math.sin(a) ** 0.9))
    heart_c, heart_s = (0.0, 3.1), 1.55
    loops = [outer, _heart(heart_c[0], heart_c[1], heart_s)]
    rot = Matrix.Translation((0, _post_y(z0), z0)) @ Matrix.Rotation(-lean, 4, "X") @ Matrix.Rotation(math.pi / 2, 4, "X")
    board = shape(WOOD, loops, 0.5, 0.14, rot, name="backrest", bevel_res=2)
    inv = rot.inverted()
    nrm = (rot.to_3x3() @ Vector((0, 0, 1))).normalized()
    pal = []
    for f in board.mesh.polygons:
        lc = inv @ Vector(f.center)
        in_heart = (lc.x - heart_c[0]) ** 2 + ((lc.y - heart_c[1]) * 1.1) ** 2 < (heart_s * 1.2) ** 2
        side = abs(Vector(f.normal).dot(nrm)) < 0.75
        if in_heart and side:
            pal.append(HEART)
        elif f.normal.z > 0.55:
            pal.append(WOOD_L)
        elif f.normal.z < -0.55:
            pal.append(WOOD_D)
        else:
            pal.append(WOOD)
    board.face_pal = pal
    # the big front / back faces shade flat (the fill is many small triangles), the round edges stay smooth
    board.flat_faces = [i for i, f in enumerate(board.mesh.polygons) if abs(Vector(f.normal).dot(nrm)) > 0.97]
    out.append(board)
    # a round rail between the posts, just above the cushion
    zr = 6.35
    out.append(_rung((-LEG_X, _post_y(zr), zr), (LEG_X, _post_y(zr), zr), 0.22, name="back_rail"))
    return out


def _loop_tube(pal, pts, r, sides=6, name="piping"):
    """A closed round tube through the closed polyline pts (a ring of rings, no caps)."""
    bm = bmesh.new()
    n = len(pts)
    pts = [Vector(p) for p in pts]
    rings = []
    for i, p in enumerate(pts):
        t = (pts[(i + 1) % n] - pts[i - 1]).normalized()
        a = t.cross(Vector((0, 0, 1))).normalized()
        b = a.cross(t).normalized()
        rings.append([bm.verts.new(p + (a * math.cos(k / sides * math.tau) + b * math.sin(k / sides * math.tau)) * r)
                      for k in range(sides)])
    for i in range(n):
        r0, r1 = rings[i], rings[(i + 1) % n]
        for k in range(sides):
            k2 = (k + 1) % sides
            bm.faces.new((r0[k], r1[k], r1[k2], r0[k2]))
    outward(bm)
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline=True, smooth=True, name=name)


def _pw(a, e):
    return math.copysign(abs(a) ** e, a)


def _cushion():
    """A puffy blue cushion: a superellipsoid pillow (boxy in plan, domed on top, flatter underneath) with a pale
    piping cord round its seam, a tuft in the middle, and two ties wrapped round the back posts."""
    out = []
    w, d, h = 2 * SEAT_X - 0.6, SEAT_Y1 - SEAT_Y0 - 0.8, 1.05
    E = 0.3                         # plan squareness
    c = Vector((0, (SEAT_Y0 + SEAT_Y1) / 2 - 0.2, SEAT_Z1 + 0.36))
    top, bot = h * 0.62, h * 0.36
    p = K.sphere(CUSH, 1.0, None, seg=24, rings=12, name="cushion")
    for v in p.mesh.vertices:
        x, y, z = v.co
        ez = 0.5 if z > 0 else 0.25
        v.co = Vector((_pw(x, E) * w / 2, _pw(y, E) * d / 2, _pw(z, ez) * (top if z > 0 else bot))) + c
    p.mesh.update()
    out.append(tone(p, CUSH, CUSH_L, CUSH_D, up=0.75, down=-0.5))
    # piping round the seam (the equator of the pillow)
    ring = []
    for k in range(32):
        a = k / 32 * math.tau
        ring.append(c + Vector((_pw(math.cos(a), E) * w / 2, _pw(math.sin(a), E) * d / 2, 0.02)))
    out.append(_loop_tube(PIPING, ring, 0.085))
    # the tuft: a small dark-blue button sunk in the top
    out.append(K.sphere(CUSH_D, 0.26, M((0, c.y, c.z + top - 0.07), scale=(1, 1, 0.45)), seg=10, rings=4, name="tuft"))
    # ties: a band round each back post just above the cushion, two little tails hanging from it
    zt = SEAT_Z1 + 0.6
    for sx in (-1, 1):
        x, y = sx * LEG_X, _post_y(zt)
        band = K.torus(CUSH_D, LEG_R * 0.98 + 0.05, 0.09, M((x, y, zt)), seg=12, mseg=4, name="tie")
        out.append(band)
        for ox, oz, rz in ((-sx * 0.15, -0.35, 0.4), (-sx * 0.45, -0.3, -0.3)):
            tail = K.sphere(CUSH_D, 0.3, M((x - sx * 0.35 + ox, y - 0.45, zt + oz), (0.3, rz, 0), (0.45, 0.25, 0.9)),
                            seg=8, rings=4, name="tie_tail")
            out.append(tail)
    return out


# ---------------------------------------------------------------- build
def build():
    p = _frame()
    p += _backrest()
    p += _cushion()
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    no_bounce(outline)
    return [body, outline] + K.markers(NAME)
