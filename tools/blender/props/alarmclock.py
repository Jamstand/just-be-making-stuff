"""
props/alarmclock.py - the AlarmClock prop (ReplicatedStorage.MapMeshes.AlarmClock). See props/__init__.py
for the conventions every prop follows.

A classic cartoon twin-bell alarm clock in the bedroom keyframe's toy style (docs/concept/bedroom_keyframe.png):
- a round, chunky teal body (a deep puck with soft rounded rims; lighter on top, darker underneath),
- a fat brass bezel ring round a cream face with big, readable hour marks (bold bars at 12 / 3 / 6 / 9,
  round dots between), two dark hands at 10:10 (the friendly "smile") and a thin red seconds hand,
- two shiny brass bells on top, tilted out like ears, each on a short stem with a little knob, and the
  striker hammer standing between them,
- two little brass ball feet splayed out underneath and a butterfly winding key on the back.
Ink: an inverted-hull outline round the solid parts; the face markings are painted (no outline).
Front (the face) = -Y, origin = floor centre. Map.luau stands it on the Nightstand's top next to the Lamp,
fitted into 16 x 18 x 10 studs (W x H x D) - the model is about 3.1 x 3.4 x 1.8 units.
"""
import math
import bmesh
import sockkit as K
from mathutils import Matrix, Vector
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "AlarmClock"

BODY = hexcol("alarmclock_body", "#25A89E")         # teal: pops against the warm wood and the lamp's glow
BODY_L = hexcol("alarmclock_body_light", "#4CCBBE")  # top-facing faces
BODY_D = hexcol("alarmclock_body_dark", "#187470")   # undersides
BRASS = hexcol("alarmclock_brass", "#EBAE34")
BRASS_L = hexcol("alarmclock_brass_light", "#FFD35C")  # top-facing faces
BRASS_D = hexcol("alarmclock_brass_dark", "#A87020")
GLINT = hexcol("alarmclock_glint", "#FFF6D8")          # the shiny spot on each bell
FACE = hexcol("alarmclock_face", "#FFF3D6")
FACE_D = hexcol("alarmclock_face_rim", "#E9D6AA")     # the face's thin edge
MARK = hexcol("alarmclock_mark", "#2B2340")           # hour marks and hands
SECOND = hexcol("alarmclock_second", "#E2463F")

# ---------------------------------------------------------------- dimensions (units)
RB = 1.3            # body radius
DEPTH = 1.2         # body depth (Y)
RIM = 0.3           # rounded rim radius (front and back edges of the puck)
FOOT_H = 0.34       # how high the body's bottom floats above the floor (the feet)
CZ = FOOT_H + RB    # body centre height
FY = -DEPTH / 2     # body front plane (y)
BEZ_R, BEZ_T = RB - 0.2, 0.17   # bezel ring: centre radius, tube radius
FACE_R = BEZ_R - 0.06           # face disc radius (tucked under the bezel)
BELL_A = math.radians(40)       # bells: angle from vertical
BELL_R, BELL_H = 0.6, 0.6       # bell radius at the lip, dome height
BELL_GAP = 0.13                 # body surface -> bell lip
SEG = 20
OUTLINE_W = 0.085


# ---------------------------------------------------------------- helpers
def _outward(bm):
    """recalc normals, then make sure the closed shell faces OUT (signed volume > 0)"""
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    vol = 0.0
    for f in bm.faces:
        v = [l.vert.co for l in f.loops]
        for k in range(1, len(v) - 1):
            vol += v[0].dot(v[k].cross(v[k + 1]))
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)


def _lathe(profile, mat, seg=SEG, name="lathe"):
    """surface of revolution around local Z (profile = [(radius, z)], r == 0 closes an end), then `mat`"""
    bm = bmesh.new()
    pts = list(profile)
    bot = top = None
    if pts[0][0] == 0:
        bot = bm.verts.new((0, 0, pts[0][1]))
        pts = pts[1:]
    if pts[-1][0] == 0:
        top = bm.verts.new((0, 0, pts[-1][1]))
        pts = pts[:-1]
    rings = [[bm.verts.new((r * math.cos(i / seg * math.tau), r * math.sin(i / seg * math.tau), z))
              for i in range(seg)] for r, z in pts]
    for a, b in zip(rings, rings[1:]):
        for i in range(seg):
            j = (i + 1) % seg
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if bot is not None:
        for i in range(seg):
            bm.faces.new((bot, rings[0][(i + 1) % seg], rings[0][i]))
    else:
        bm.faces.new(list(reversed(rings[0])))
    if top is not None:
        for i in range(seg):
            bm.faces.new((top, rings[-1][i], rings[-1][(i + 1) % seg]))
    else:
        bm.faces.new(rings[-1])
    _outward(bm)
    bmesh.ops.transform(bm, matrix=mat, verts=bm.verts)
    return K.Piece(K._bm_to_mesh(bm, name), 0, True, True, name)


def _arc(cr, cz, r, a0, a1, n):
    return [(cr + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cz + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def _tone(piece, base, light, dark, up=0.55, down=-0.5):
    piece.face_pal = [light if f.normal.z > up else (dark if f.normal.z < down else base)
                      for f in piece.mesh.polygons]
    return piece


def _box(pal, size, mat, name="mark"):
    """a plain painted plate (no bevel, no outline)"""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.transform(bm, matrix=mat @ Matrix.Diagonal(Vector((size[0], size[1], size[2], 1.0))), verts=bm.verts)
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline=False, smooth=False, name=name)


FRONT_ROT = (math.pi / 2, 0, 0)  # lathe axis (local +Z) -> world -Y (toward the viewer)


def _face_mat(angle, r, y):
    """placement on the clock face: `angle` clockwise from 12 o'clock, `r` out from the centre, at depth y;
    the part's local X runs along the radius, local Z out of the face"""
    a = math.radians(angle)
    xr = Vector((math.sin(a), 0, math.cos(a)))  # along the radius
    zr = Vector((0, -1, 0))                      # out of the face
    m = Matrix((xr, zr.cross(xr), zr)).transposed().to_4x4()
    m.translation = Vector((r * math.sin(a), y, CZ + r * math.cos(a)))
    return m


# ---------------------------------------------------------------- parts
def _body():
    """deep puck: back cap -> rounded back rim -> side -> rounded front rim -> flat front (under the face)"""
    zb, zf = -DEPTH / 2, DEPTH / 2   # local z: back / front (the lathe axis becomes -Y)
    prof = ([(0, zb), (RB - RIM, zb)] + _arc(RB - RIM, zb + RIM, RIM, -90, 0, 3)[1:]
            + _arc(RB - RIM, zf - RIM, RIM, 0, 90, 3) + [(0, zf)])
    p = _lathe(prof, M((0, 0, CZ), FRONT_ROT), name="body")
    return _tone(p, BODY, BODY_L, BODY_D)


def _bezel():
    t = K.torus(BRASS, BEZ_R, BEZ_T, M((0, FY - 0.02, CZ), FRONT_ROT), seg=SEG, mseg=6, name="bezel")
    return _tone(t, BRASS, BRASS_L, BRASS_D, up=0.5, down=-0.5)


def _face():
    """cream face disc just in front of the body, under the bezel, plus its marks and hands"""
    parts = []
    face = K.cylinder(FACE, FACE_R, 0.08, M((0, FY - 0.02, CZ), FRONT_ROT), seg=SEG, name="face")
    face.face_pal = [FACE if abs(f.normal.y) > 0.9 else FACE_D for f in face.mesh.polygons]
    face.outline = False
    parts.append(face)
    fy = FY - 0.07  # the face's front plane
    for h in range(12):
        ang = h * 30
        if h % 3 == 0:  # bold bars at 12 / 3 / 6 / 9
            parts.append(_box(MARK, (0.26, 0.11, 0.04), _face_mat(ang, FACE_R - 0.29, fy)))
        else:           # round dots between
            dot = K.cylinder(MARK, 0.055, 0.04, _face_mat(ang, FACE_R - 0.24, fy), seg=6, outline=False, smooth=False,
                             name="mark")
            parts.append(dot)
    # hands at 10:10 (hour hand a little past 10), each a bar with a rounded tip; a thin red seconds hand
    for ang, length, width, y in ((305, 0.5, 0.13, fy - 0.03), (60, 0.74, 0.1, fy - 0.06)):
        parts.append(_box(MARK, (length, width, 0.03), _face_mat(ang, length / 2 - 0.06, y), name="hand"))
        parts.append(K.cylinder(MARK, width * 0.72, 0.03, _face_mat(ang, length - 0.06, y), seg=6, outline=False,
                                smooth=False, name="hand_tip"))
    parts.append(_box(SECOND, (0.92, 0.035, 0.02), _face_mat(200, 0.26, fy - 0.085), name="second"))
    cap = K.sphere(BRASS, 1.0, M((0, fy - 0.08, CZ), scale=(0.1, 0.05, 0.1)), seg=8, rings=4, outline=False,
                   name="cap")
    parts.append(_tone(cap, BRASS, BRASS_L, BRASS_D, up=0.3))
    return parts


def _bell(side):
    """a shiny brass dome tilted out by BELL_A (opening toward the body), on a stem, with a knob on top;
    the lit side (toward the upper left lamp light) gets the highlight tone"""
    a = side * BELL_A
    d = Vector((math.sin(a), 0, math.cos(a)))
    base = Vector((0, 0.05, CZ)) + d * (RB + BELL_GAP)
    prof = [(0, 0.06), (BELL_R * 0.86, 0.06), (BELL_R, 0.0), (BELL_R * 0.98, 0.08), (BELL_R * 0.92, 0.22),
            (BELL_R * 0.8, 0.36), (BELL_R * 0.6, 0.48), (BELL_R * 0.32, 0.57), (0, BELL_H)]
    mat = M(tuple(base), (0, a, 0))
    bell = _lathe(prof, mat, seg=14, name="bell")
    # toon bands by height up the dome (clean edges, no per-face speckle): dark mouth and lip, brass sides,
    # a lit shoulder and cap - plus one bright glint patch on the side facing the room / the lamp
    inv = mat.inverted()
    lt = inv.to_3x3() @ Vector((-0.55, -0.8, 0.25))
    glint_az = math.atan2(lt.y, lt.x)
    pals = []
    for f in bell.mesh.polygons:
        c = inv @ f.center
        az = math.atan2(c.y, c.x)
        daz = abs((az - glint_az + math.pi) % math.tau - math.pi)
        if c.z < 0.075:
            pals.append(BRASS_D)
        elif 0.22 < c.z < 0.36 and daz < 0.5:
            pals.append(GLINT)
        elif c.z > 0.36:
            pals.append(BRASS_L)
        else:
            pals.append(BRASS)
    bell.face_pal = pals
    parts = [bell]
    s0, s1 = Vector((0, 0.05, CZ)) + d * (RB - 0.1), base + d * 0.12
    stem = K.cylinder(BRASS_D, 0.075, (s1 - s0).length, M(tuple((s0 + s1) / 2), (0, a, 0)), seg=8, name="stem")
    parts.append(stem)
    knob = K.sphere(BRASS, 0.11, M(tuple(base + d * (BELL_H + 0.06))), seg=8, rings=5, name="knob")
    parts.append(_tone(knob, BRASS, BRASS_L, BRASS_D, up=0.4))
    return parts


def _hammer():
    """the striker standing up between the bells: a short rod with a brass ball"""
    z0, z1 = CZ + RB - 0.1, CZ + RB + 0.32
    rod = K.cylinder(BRASS_D, 0.06, z1 - z0, M((0, 0.1, (z0 + z1) / 2)), seg=8, name="hammer_rod")
    ball = K.sphere(BRASS, 0.15, M((0, 0.1, z1 + 0.08)), seg=10, rings=6, name="hammer")
    return [rod, _tone(ball, BRASS, BRASS_L, BRASS_D, up=0.4)]


def _feet():
    parts = []
    for sx in (-1, 1):
        a = math.radians(34) * sx
        top = Vector((RB * 0.8 * math.sin(a), 0, CZ - RB * 0.8 * math.cos(a)))
        foot = Vector((0.98 * sx, 0, 0.17))
        mid = (top + foot) / 2
        leg_dir = (top - foot).normalized()
        tilt = math.atan2(leg_dir.x, leg_dir.z)
        parts.append(K.cylinder(BRASS_D, 0.08, (top - foot).length, M(tuple(mid), (0, tilt, 0)), seg=8, name="leg"))
        ball = K.sphere(BRASS, 1.0, M(tuple(foot), scale=(0.2, 0.2, 0.17)), seg=8, rings=5, name="foot")
        parts.append(_tone(ball, BRASS, BRASS_L, BRASS_D, up=0.45))
    return parts


def _key():
    """butterfly winding key on the back"""
    by = DEPTH / 2
    stem = K.cylinder(BRASS_D, 0.07, 0.24, M((0, by + 0.1, CZ + 0.15), (math.pi / 2, 0, 0)), seg=6, name="key_stem")
    parts = [stem]
    for sx in (-1, 1):
        wing = K.sphere(BRASS, 1.0, M((0.19 * sx, by + 0.26, CZ + 0.15), (0, 0, 0.2 * sx), (0.22, 0.12, 0.05)),
                        seg=8, rings=4, name="key")
        parts.append(_tone(wing, BRASS, BRASS_L, BRASS_D, up=0.4))
    return parts


def build():
    p = [_body(), _bezel()]
    p += _face()
    p += _bell(-1) + _bell(1)
    p += _hammer()
    p += _feet()
    p += _key()
    body, outline = K.finish(p, NAME, outline_width=OUTLINE_W)
    # Cycles-only (no effect on the GLB / game): keep the hull from blocking bounce/sky light in previews
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False
    return [body, outline] + K.markers(NAME)
