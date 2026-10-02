"""
props/door.py - the Door prop (ReplicatedStorage.MapMeshes.Door): the kid's bedroom door in its
frame. See props/__init__.py for the conventions every prop follows.

A chunky cream-painted casing (side casings on plinth blocks, a head casing under a cap moulding) round
a soft-blue door with four raised panels (lighter top bevels, a painted groove round each), a round
brass knob on a rosette, two brass hinges, a wooden "SOCK ZONE / KEEP OUT!" sign hanging from a red
pushpin on a string, and two stickers (a yellow star, a striped sock) on the lower panels.

Wall-mounted: the back is flat on the wall at y = 0 (the door leaf itself is a slab from the wall to
its face), the front faces -Y; origin = bottom centre of the back plane. Solid size 3.5 W x 7.5 H x
0.36 D units (knob front; Map fit box 140 x 300 x 16).
Exported: `Door` (textured body), `Door_Outline` (inverted hull) and the markers.
"""
import math
import bmesh
import bpy
from mathutils import Vector
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Door"
EXPORT_DIR = "map"

# ---------------------------------------------------------------- palette
DOOR = hexcol("door_blue", "#7EA3DD")           # soft blue paint (front faces)
DOOR_L = hexcol("door_blue_light", "#A6C3EF")   # top-facing bevels
DOOR_S = hexcol("door_blue_side", "#6489C6")    # side faces
DOOR_D = hexcol("door_blue_dark", "#4D6CAA")    # undersides
GROOVE = hexcol("door_groove", "#3F5A96")       # painted groove round the panels
CASE = hexcol("door_casing", "#F2E4C8")         # cream casing
CASE_L = hexcol("door_casing_light", "#FFF5E2")
CASE_S = hexcol("door_casing_side", "#D9C4A2")
CASE_D = hexcol("door_casing_dark", "#B79F82")
JAMB = hexcol("door_jamb", "#A99179")           # the jamb in the door's shadow
BRASS = hexcol("door_brass", "#E0AE48")
BRASS_L = hexcol("door_brass_light", "#FFD97A")
BRASS_D = hexcol("door_brass_dark", "#A8772C")
SIGN = hexcol("door_sign", "#EDB873")           # light wood plaque
SIGN_L = hexcol("door_sign_light", "#FFD79A")
SIGN_D = hexcol("door_sign_dark", "#B98247")
SIGN_IN = hexcol("door_sign_panel", "#FFF1D4")  # cream painted face
TXT = hexcol("door_sign_text", "#3A2A6E")       # "SOCK ZONE" - deep purple ink
TXT_R = hexcol("door_sign_red", "#D8403A")      # "KEEP OUT!"
STRING = hexcol("door_string", "#B23A3A")
PIN = hexcol("door_pin", "#E8463F")
PIN_L = hexcol("door_pin_light", "#FF8A7A")
ST_WHITE = hexcol("door_sticker_white", "#FFFDF6")
ST_STAR = hexcol("door_sticker_star", "#FFCF3F")
ST_STAR_D = hexcol("door_sticker_star_dark", "#F2A72E")
ST_SOCK = hexcol("door_sticker_sock", "#3FB98A")   # mint-green sock
ST_SOCK_S = hexcol("door_sticker_sock_stripe", "#FFE07A")
ST_SOCK_C = hexcol("door_sticker_sock_cuff", "#F6F0E4")

# ---------------------------------------------------------------- layout (units; Z up, front = -Y, wall at y = 0)
OUT = 0.045
HALF_W = 1.70                     # casing outer half width (the cap moulding overhangs to 1.75)
CAS_W = 0.34                      # casing width
CAS_Y = -0.16                     # casing front
X_IN = HALF_W - CAS_W             # opening half width (1.36)
Z_OPEN = 6.95                     # opening top = head casing bottom
HEAD_Z1 = 7.33                    # head casing top
CAP_Z1 = 7.5                      # cap moulding top
DOOR_Y = -0.08                    # door face
DX = X_IN - 0.02                  # door leaf half width
PANEL_Y = -0.135                  # raised panel front
KNOB = (1.04, 3.08)               # knob centre (x, z) on the lock rail


# ---------------------------------------------------------------- helpers
def _paint(piece, front, side, top=None, bottom=None, cut=0.6):
    """Toon tones by face normal: up -> top, down -> bottom, facing the front -> front, else side."""
    pals = []
    for f in piece.mesh.polygons:
        n = f.normal
        if top is not None and n.z > cut:
            pals.append(top)
        elif bottom is not None and n.z < -cut:
            pals.append(bottom)
        elif n.y < -0.85:
            pals.append(front)
        else:
            pals.append(side)
    piece.face_pal = pals
    return piece


def _box(pal, x0, x1, z0, z1, y0, y1, bevel=0.03, segs=2, outline=True, name="box"):
    """Rounded box from corner ranges (y0 = back, y1 = front, y1 < y0)."""
    return K.rounded_box(pal, (x1 - x0, y0 - y1, z1 - z0), M(((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)),
                         bevel=bevel, segments=segs, outline=outline, name=name)


def _flat(pts, y, pal, name, rot=0.0, at=(0.0, 0.0)):
    """A flat 2D shape (x, z) facing the front at depth y, rotated by `rot` and moved to `at`.
    Concave outlines are ear-clipped."""
    c, s = math.cos(rot), math.sin(rot)
    bm = bmesh.new()
    vs = [bm.verts.new((at[0] + x * c - z * s, y, at[1] + x * s + z * c)) for x, z in pts]
    f = bm.faces.new(vs)
    f.normal_update()
    if f.normal.y > 0:
        f.normal_flip()
    bmesh.ops.triangulate(bm, faces=[f], quad_method="BEAUTY", ngon_method="EAR_CLIP")
    for f in bm.faces:
        f.normal_update()
        if f.normal.y > 0:
            f.normal_flip()
    return K.Piece(K._bm_to_mesh(bm, name), pal, False, False, name)


def _text(pal, body, size, y, x, z, rot=0.0, depth=0.012, spacing=1.12, name="text"):
    """Chunky raised lettering: Blender's built-in font, its glyph outlines thickened (offset) so the
    thin sans reads bold; facing the front, its back face at y."""
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = body
    cu.size = size
    cu.extrude = depth
    cu.offset = 0.042 * size
    cu.space_character = spacing
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    cu.resolution_u = 3
    obj = bpy.data.objects.new(name, cu)
    K.link(obj)
    obj.matrix_world = M((x, y - depth, z), rot=(math.pi / 2, rot, 0))
    return K.Piece(K.bake_object(obj), pal, False, False, name)


def _star_pts(r, inner=0.48, n=5):
    return [((r if k % 2 == 0 else r * inner) * math.cos(math.pi / 2 + k * math.pi / n),
             (r if k % 2 == 0 else r * inner) * math.sin(math.pi / 2 + k * math.pi / n)) for k in range(2 * n)]


def _round_pts(pts, r, n=3):
    """Rounds every corner of a polygon with a small arc (cheap fillet for sticker outlines)."""
    out = []
    m = len(pts)
    for i in range(m):
        p0, p1, p2 = Vector(pts[i - 1]), Vector(pts[i]), Vector(pts[(i + 1) % m])
        a, b = (p0 - p1), (p2 - p1)
        la, lb = a.length, b.length
        rr = min(r, la * 0.45, lb * 0.45)
        a.normalize()
        b.normalize()
        q0, q2 = p1 + a * rr, p1 + b * rr
        for k in range(n + 1):  # quadratic bezier q0 -> p1 -> q2
            t = k / n
            q = q0 * (1 - t) ** 2 + p1 * 2 * t * (1 - t) + q2 * t * t
            out.append((q.x, q.y))
    return out


def _offset(pts, d):
    """Pushes a CCW polygon outward by d (miter, clamped) - the white border of a sticker."""
    out = []
    m = len(pts)
    for i in range(m):
        p0, p1, p2 = Vector(pts[i - 1]), Vector(pts[i]), Vector(pts[(i + 1) % m])
        e0, e1 = (p1 - p0).normalized(), (p2 - p1).normalized()
        n0, n1 = Vector((e0.y, -e0.x)), Vector((e1.y, -e1.x))
        nb = (n0 + n1)
        if nb.length < 1e-6:
            nb = n0
        nb.normalize()
        k = d / max(0.35, nb.dot(n0))
        q = p1 + nb * k
        out.append((q.x, q.y))
    return out


def _ccw(pts):
    a = sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))
    return pts if a > 0 else pts[::-1]


# ---------------------------------------------------------------- parts
def _casing(p):
    # side casings with plinth blocks at the foot
    for s in (-1, 1):
        x0, x1 = sorted((s * X_IN, s * HALF_W))
        p.append(_paint(_box(CASE, x0, x1, 0.42, Z_OPEN + 0.02, 0.0, CAS_Y, bevel=0.045, name="side_casing"),
                        CASE, CASE_S, CASE_L, CASE_D))
        xp0, xp1 = sorted((s * (X_IN - 0.01), s * (HALF_W + 0.02)))
        p.append(_paint(_box(CASE, xp0, xp1, 0.0, 0.46, 0.0, CAS_Y - 0.035, bevel=0.04, name="plinth"),
                        CASE, CASE_S, CASE_L, CASE_D))
        # the jamb: the opening's side wall from the door face to the casing front, in shadow
        xj0, xj1 = sorted((s * (X_IN - 0.012), s * (X_IN + 0.02)))
        p.append(_box(JAMB, xj0, xj1, 0.0, Z_OPEN, -0.01, CAS_Y + 0.01, bevel=0.005, segs=1, outline=False, name="jamb"))
    # head casing and its cap moulding
    p.append(_paint(_box(CASE, -HALF_W, HALF_W, Z_OPEN - 0.01, HEAD_Z1, 0.0, CAS_Y, bevel=0.045, name="head"),
                    CASE, CASE_S, CASE_L, CASE_D))
    p.append(_paint(_box(CASE, -HALF_W - 0.05, HALF_W + 0.05, HEAD_Z1 - 0.02, CAP_Z1, 0.0, CAS_Y - 0.05, bevel=0.05, name="cap"),
                    CASE, CASE_S, CASE_L, CASE_D))
    p.append(_box(JAMB, -X_IN, X_IN, Z_OPEN - 0.02, Z_OPEN + 0.012, -0.01, CAS_Y + 0.01, bevel=0.005, segs=1, outline=False, name="head_jamb"))


def _leaf(p):
    """The door: a slab from the wall to its face, four raised panels with a painted groove round each."""
    p.append(_paint(_box(DOOR, -DX, DX, 0.02, Z_OPEN - 0.02, 0.0, DOOR_Y, bevel=0.03, name="leaf"),
                    DOOR, DOOR_S, DOOR_L, DOOR_D))
    stile, mull = 0.30, 0.26
    rows = [(0.62, 2.82), (3.34, 6.56)]   # lower / upper panels (z ranges); the lock rail between
    cols = [(-DX + stile, -mull / 2), (mull / 2, DX - stile)]
    for z0, z1 in rows:
        for x0, x1 in cols:
            p.append(_flat([(x0 - 0.05, z0 - 0.05), (x1 + 0.05, z0 - 0.05), (x1 + 0.05, z1 + 0.05), (x0 - 0.05, z1 + 0.05)],
                           DOOR_Y - 0.004, GROOVE, "groove"))
            panel = _box(DOOR, x0, x1, z0, z1, DOOR_Y + 0.01, PANEL_Y, bevel=0.045, segs=2, name="panel")
            p.append(_paint(panel, DOOR, DOOR_S, DOOR_L, DOOR_D, cut=0.5))
    # brass hinges on the left edge
    for z in (1.05, 5.95):
        hb = K.cylinder(BRASS, 0.055, 0.42, M((-DX - 0.005, DOOR_Y - 0.01, z)), seg=10, name="hinge")
        p.append(_paint(hb, BRASS, BRASS_L, BRASS_L, BRASS_D))
        p.append(_paint(K.sphere(BRASS, 0.06, M((-DX - 0.005, DOOR_Y - 0.01, z + 0.23), scale=(1, 1, 0.7)), seg=10, rings=5, outline=False, name="hinge_cap"),
                        BRASS, BRASS, BRASS_L, BRASS_D))


def _knob(p, ink):
    x, z = KNOB
    # rosette backplate
    ros = K.cylinder(BRASS, 0.2, 0.035, M((x, DOOR_Y - 0.0175, z), rot=(math.pi / 2, 0, 0)), seg=20, name="rosette")
    p.append(_paint(ros, BRASS, BRASS_D, BRASS_L, BRASS_D))
    rim = K.torus(BRASS, 0.18, 0.025, M((x, DOOR_Y - 0.035, z), rot=(math.pi / 2, 0, 0)), seg=20, mseg=6, outline=False, name="rosette_rim")
    p.append(_paint(rim, BRASS, BRASS_L, BRASS_D))
    neck = K.cylinder(BRASS, 0.055, 0.1, M((x, DOOR_Y - 0.09, z), rot=(math.pi / 2, 0, 0)), seg=12, radius2=0.075, outline=False, name="neck")
    p.append(_paint(neck, BRASS_D, BRASS_D, BRASS, BRASS_D))
    km = M((x, -0.232, z), scale=(1, 0.8, 1))
    knob = K.sphere(BRASS, 0.15, km, seg=18, rings=10, outline=False, name="knob")
    p.append(_paint(knob, BRASS, BRASS, BRASS_L, BRASS_D, cut=0.45))
    # the knob's ink: an eroded copy (the hull is OUT wide, the line should be a bit finer)
    ink.append(K.sphere(0, 0.15 - 0.012, km, seg=18, rings=10, name="knob_ink"))
    # a glint
    p.append(K.sphere(K.WHITE, 0.035, M((x - 0.06, -0.338, z + 0.065), scale=(1, 0.5, 1.2)), seg=8, rings=4, outline=False, name="glint"))


def _sign(p, ink):
    """Wooden plaque hanging from a red pushpin on a red string, slightly askew."""
    cx, cz, tilt = 0.0, 5.0, math.radians(-4)
    w, h = 2.04, 1.1
    back_y = PANEL_Y - 0.008
    front_y = back_y - 0.07
    # the plaque hangs over the mullion between the upper panels
    plaque = K.rounded_box(SIGN, (w, back_y - front_y, h), M((cx, (back_y + front_y) / 2, cz), rot=(0, tilt, 0)),
                           bevel=0.045, segments=2, name="plaque")
    p.append(_paint(plaque, SIGN, SIGN_D, SIGN_L, SIGN_D, cut=0.5))

    def rot(x, z):  # plaque-local (x, z) -> world (x, z) (rot about Y by tilt: x' = x c + z s ...)
        return cx + x * math.cos(tilt) + z * math.sin(tilt), cz - x * math.sin(tilt) + z * math.cos(tilt)
    # cream painted face with a soft rounded border
    face = _round_pts([(-w / 2 + 0.09, -h / 2 + 0.09), (w / 2 - 0.09, -h / 2 + 0.09), (w / 2 - 0.09, h / 2 - 0.09), (-w / 2 + 0.09, h / 2 - 0.09)], 0.08)
    p.append(_flat([rot(x, z) for x, z in face], front_y - 0.004, SIGN_IN, "sign_face"))
    # lettering
    for txt, size, dz, pal, sp in (("SOCK ZONE", 0.29, 0.16, TXT, 1.1), ("KEEP OUT!", 0.25, -0.2, TXT_R, 1.2)):
        tx, tz = rot(0.0, dz)
        p.append(_text(pal, txt, size, front_y - 0.006, tx, tz, rot=0.0, spacing=sp, name="sign_text"))
        # match the plaque's tilt: rotate the text about its own centre in the wall plane
        tp = p[-1]
        tp.mesh.transform(M((tx, 0, tz)) @ M(rot=(0, tilt, 0)) @ M((-tx, 0, -tz)))
        tp.mesh.update()
    # pushpin and the string to the plaque's top corners
    pin = (0.0, 6.2)
    pin_y = PANEL_Y - 0.02
    for sx in (-1, 1):
        ex, ez = rot(sx * (w / 2 - 0.16), h / 2 - 0.02)
        a, b = Vector((pin[0], pin_y + 0.005, pin[1] - 0.02)), Vector((ex, front_y + 0.02, ez))
        d = b - a
        mid = (a + b) / 2
        ang = math.atan2(d.x, d.z)
        st = K.cylinder(STRING, 0.018, d.length, M((mid.x, mid.y, mid.z), rot=(0, ang, 0)), seg=6, outline=False, name="string")
        p.append(st)
        # little eyelet on the plaque
        p.append(K.cylinder(BRASS, 0.035, 0.02, M((ex, front_y - 0.002, ez), rot=(math.pi / 2, 0, 0)), seg=10, outline=False, name="eyelet"))
    head = K.sphere(PIN, 0.085, M((pin[0], pin_y - 0.03, pin[1]), scale=(1, 0.8, 1)), seg=12, rings=6, outline=False, name="pin")
    p.append(_paint(head, PIN, PIN, PIN_L, STRING, cut=0.45))
    ink.append(K.sphere(0, 0.085 - 0.015, M((pin[0], pin_y - 0.03, pin[1]), scale=(1, 0.8, 1)), seg=12, rings=6, name="pin_ink"))


def _stickers(p):
    y0 = PANEL_Y - 0.006
    # yellow star with a white border, on the lower left panel
    star = _ccw(_round_pts(_star_pts(0.27, 0.5), 0.035, 2))
    at, r = (-0.6, 2.05), math.radians(12)
    p.append(_flat(_offset(star, 0.06), y0, ST_WHITE, "sticker_border", rot=r, at=at))
    p.append(_flat(star, y0 - 0.003, ST_STAR, "sticker_star", rot=r, at=at))
    p.append(_flat(_ccw(_round_pts(_star_pts(0.12, 0.5), 0.02, 2)), y0 - 0.006, ST_STAR_D, "sticker_star_c", rot=r, at=(at[0], at[1] - 0.005)))
    # a mint sock with a cream cuff and yellow stripes, on the lower right panel
    sock = [(-0.13, 0.28), (0.11, 0.28), (0.11, -0.04), (0.3, -0.12), (0.33, -0.2), (0.3, -0.27),
            (0.0, -0.27), (-0.12, -0.22), (-0.15, -0.13), (-0.13, -0.04)]
    sock = _ccw(_round_pts(sock, 0.07, 3))
    at, r = (0.6, 1.55), math.radians(-14)
    p.append(_flat(_offset(sock, 0.06), y0, ST_WHITE, "sticker_border", rot=r, at=at))
    p.append(_flat(sock, y0 - 0.003, ST_SOCK, "sticker_sock", rot=r, at=at))
    for z0, z1, pal in ((0.17, 0.28, ST_SOCK_C), (0.06, 0.11, ST_SOCK_S), (-0.03, 0.02, ST_SOCK_S)):
        band = [(-0.13, z0), (0.11, z0), (0.11, z1), (-0.13, z1)]
        p.append(_flat(band, y0 - 0.006, pal, "sticker_band", rot=r, at=at))
    toe = _ccw(_round_pts([(0.18, -0.27), (0.3, -0.27), (0.33, -0.2), (0.3, -0.12), (0.18, -0.08)], 0.04, 2))
    p.append(_flat(toe, y0 - 0.006, ST_SOCK_S, "sticker_toe", rot=r, at=at))


def _camera_only(outline):
    """Cycles-only flags (no effect on the GLB / game): keep the hull from blocking bounce/sky light in
    the preview renders."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False


def build():
    p, ink = [], []
    _casing(p)
    _leaf(p)
    _knob(p, ink)
    _sign(p, ink)
    _stickers(p)
    body, outline = K.finish(p, NAME, outline_width=OUT, outline_only=ink)
    _camera_only(outline)
    return [body, outline] + K.markers(NAME)
