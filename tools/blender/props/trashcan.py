"""
props/trashcan.py - the TrashCan prop (ReplicatedStorage.MapMeshes.TrashCan): a kid's round waste
bin on the bedroom floor. See props/__init__.py for the conventions every prop follows.

Art: a slightly tapered round bin painted sky blue with white stars, a dark blue foot ring and a fat
rolled rim in a lighter blue; it is full to the brim with crumpled paper balls (low-poly, faceted
like real crumpled paper, two tones; one is a yellow sticky note) and one more ball has missed and
lies on the floor in front. A yellow sock with pink stripes, heel and toe hangs over the front-right
of the rim: its cuff is down among the paper inside, the leg drapes over the rim and down the outside
and the foot flops sideways along the wall.

Floor prop: origin = floor centre of the bin, front faces -Y. About 4.5 x 6.0 x 4.8 units with the hull (Map fit
box 50 x 64 x 50 studs).
"""
import math
import random
import bmesh
import bpy
from mathutils import Vector
import sockkit as K
from sockkit import hexcol
from props.common import CREAM, DUCK_Y, DUCK_YD, GLOBE, YELLOW

NAME = "TrashCan"
EXPORT_DIR = "map"

BIN = hexcol("trashcan_blue", "#4C86DA")
BIN_L = hexcol("trashcan_blue_light", "#7DB3F2")
BIN_D = hexcol("trashcan_blue_dark", "#2F5CA8")
INSIDE = hexcol("trashcan_inside", "#24325E")
PAPER_D = hexcol("trashcan_paper_shade", "#D6D0C4")
SOCK_S = hexcol("trashcan_sock_stripe", "#FF7A8C")
# shared tones (one 32 x 32 palette serves the whole game)
STAR = PAPER = K.WHITE
STAR_Y = NOTE = GLOBE
NOTE_D = YELLOW
SOCK, SOCK_IN, SOCK_W = DUCK_Y, DUCK_YD, CREAM

OUTLINE = 0.07        # hull width (~1.2% of the height)
SEG = 30              # segments round the bin
R_FOOT = 1.72         # wall radius at the foot
R_TOP = 1.98          # wall radius under the rim
Z_FOOT = 0.3          # top of the foot ring
Z_TOP = 5.1           # wall meets the rim
RIM_R = 0.17          # rolled rim tube radius
FILL_Z = 4.15         # the fake bottom inside: the paper pile hides it
SOCK_ANG = math.radians(-78)  # where the sock hangs over the rim (front = -90)


def wall_r(z):
    t = min(max((z - Z_FOOT) / (Z_TOP - Z_FOOT), 0.0), 1.0)
    return R_FOOT + (R_TOP - R_FOOT) * t


def _bin():
    """The bin as one lathed closed surface: foot ring, tapered wall, rolled rim, inner wall down to
    a dark false bottom. Colours by profile span."""
    prof = []  # (r, z, colour of the span starting here)
    prof.append((0.0, 0.0, BIN_D))
    prof.append((R_FOOT - 0.12, 0.0, BIN_D))
    for k in range(5):  # foot ring: a rounded band
        a = -math.pi / 2 + math.pi * k / 4
        prof.append((R_FOOT - 0.04 + 0.1 * math.cos(a), 0.15 + 0.15 * math.sin(a), BIN_D))
    nz = 8
    for k in range(nz + 1):
        z = Z_FOOT + 0.02 + (Z_TOP - Z_FOOT - 0.02) * k / nz
        prof.append((wall_r(z), z, BIN if k < nz else BIN_L))
    # rolled rim: round the tube from the outside, over the top, to the inside
    cx, cz = R_TOP + 0.02, Z_TOP + RIM_R * 0.6
    for k in range(9):
        a = -math.pi * 0.62 + (math.pi * 1.62) * k / 8
        prof.append((cx + RIM_R * math.cos(a), cz + RIM_R * math.sin(a), BIN_L))
    prof.append((R_TOP - 0.16, Z_TOP + 0.05, INSIDE))
    prof.append((R_TOP - 0.2, FILL_Z, INSIDE))
    prof.append((0.0, FILL_Z, INSIDE))
    bm = bmesh.new()
    centres = {j: bm.verts.new((0.0, 0.0, z)) for j, (r, z, _) in enumerate(prof) if r < 1e-6}
    rings = []
    for i in range(SEG):
        a = math.tau * i / SEG
        ca, sa = math.cos(a), math.sin(a)
        rings.append([centres[j] if j in centres else bm.verts.new((r * ca, r * sa, z)) for j, (r, z, _) in enumerate(prof)])
    pals = []
    n = len(prof)
    for i in range(SEG):
        r0, r1 = rings[i], rings[(i + 1) % SEG]
        for j in range(n - 1):
            q = [r0[j], r1[j], r1[j + 1], r0[j + 1]]
            if prof[j][0] < 1e-6:
                q = [r0[j], r1[j + 1], r0[j + 1]]
            elif prof[j + 1][0] < 1e-6:
                q = [r0[j], r1[j], r0[j + 1]]
            bm.faces.new(q)
            pals.append(prof[j][2])
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("bin")
    bm.to_mesh(me)
    bm.free()
    pc = K.Piece(me, pals, outline=True, smooth=True, name="bin")
    # flat-looking bottom and false bottom
    pc.flat_faces = [i for i, f in enumerate(me.polygons) if abs(f.normal.z) > 0.95]
    return pc


def _decal(pts2d, ang0, pal, lift=0.025, name="decal"):
    """A flat shape painted on the outer wall: pts2d are (arc length, z) around the centre
    (wall angle ang0); a fan from its centre, wrapped onto the wall a hair outside it."""
    cu = sum(p[0] for p in pts2d) / len(pts2d)
    cz = sum(p[1] for p in pts2d) / len(pts2d)

    def to3d(u, z):
        r = wall_r(z) + lift
        a = ang0 + u / r
        return (r * math.cos(a), r * math.sin(a), z)
    bm = bmesh.new()
    c = bm.verts.new(to3d(cu, cz))
    ring = [bm.verts.new(to3d(u, z)) for u, z in pts2d]
    for i in range(len(ring)):
        bm.faces.new((c, ring[i], ring[(i + 1) % len(ring)]))
    bm.normal_update()
    for f in bm.faces:
        out = Vector((f.calc_center_median().x, f.calc_center_median().y, 0.0))
        if f.normal.dot(out) < 0:
            f.normal_flip()
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pal, outline=False, smooth=False, name=name)


def _star_pts(r, rot=0.0, k=5):
    out = []
    for i in range(2 * k):
        rr = r if i % 2 == 0 else r * 0.45
        a = rot + math.pi / 2 + math.pi * i / k
        out.append((rr * math.cos(a), rr * math.sin(a)))
    return out


def _stars():
    out = []
    # (wall angle deg, z, size, rotation, colour): scattered all round, clear of the sock
    spec = [(-112, 3.9, 0.42, 0.1, STAR), (-128, 2.3, 0.32, -0.2, STAR), (-88, 1.5, 0.34, 0.3, STAR),
            (-150, 4.3, 0.26, 0.0, STAR_Y), (-112, 0.85, 0.2, 0.2, STAR), (-140, 3.2, 0.18, 0.5, STAR),
            (-70, 2.35, 0.24, -0.3, STAR_Y), (-28, 4.15, 0.34, 0.2, STAR), (-30, 1.6, 0.3, -0.1, STAR),
            (-5, 2.8, 0.2, 0.4, STAR_Y), (20, 1.0, 0.28, 0.0, STAR), (175, 3.4, 0.36, 0.3, STAR),
            (150, 1.6, 0.3, -0.2, STAR), (-175, 2.0, 0.22, 0.1, STAR_Y), (60, 3.6, 0.32, 0.2, STAR),
            (100, 2.1, 0.3, -0.3, STAR), (120, 4.2, 0.22, 0.0, STAR_Y), (45, 1.9, 0.2, 0.3, STAR),
            (80, 4.4, 0.26, 0.1, STAR), (75, 1.0, 0.22, -0.2, STAR_Y), (130, 3.0, 0.2, 0.4, STAR),
            (30, 3.3, 0.24, -0.1, STAR_Y), (-160, 4.6, 0.2, 0.2, STAR),
            (-48, 0.9, 0.22, 0.1, STAR_Y), (-60, 1.6, 0.18, -0.2, STAR)]
    for deg, z, s, rot, pal in spec:
        pts = [(u, z + v) for u, v in _star_pts(s, rot)]
        out.append(_decal(pts, math.radians(deg), pal, name="star"))
    for deg, z in ((-118, 3.1), (-98, 2.6), (-135, 1.25), (-160, 2.9), (-38, 2.6), (5, 1.7), (80, 2.7), (-102, 4.6)):
        pts = [(0.07 * math.cos(a), z + 0.07 * math.sin(a)) for a in [math.tau * k / 8 for k in range(8)]]
        out.append(_decal(pts, math.radians(deg), STAR, name="dot"))
    return out


def _paper_ball(c, r, seed, pals=(PAPER, PAPER_D), squash=1.0, subdiv=2):
    """A crumpled paper ball: a jittered low-poly icosphere, flat shaded, two tones of creases."""
    rnd = random.Random(seed)
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
    for v in bm.verts:
        k = 0.82 + 0.3 * rnd.random()
        v.co = Vector((v.co.x * k * r, v.co.y * k * r, v.co.z * k * r * squash)) + Vector(c)
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(14), verts=bm.verts, edges=bm.edges)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    me = bpy.data.meshes.new("ball")
    bm.to_mesh(me)
    bm.free()
    light = Vector((-0.4, -0.6, 0.7)).normalized()
    pal = []
    for f in me.polygons:
        # creases facing away from the light get the shade tone, a few random ones too
        pal.append(pals[1] if f.normal.dot(light) < -0.1 or rnd.random() < 0.18 else pals[0])
    return K.Piece(me, pal, outline=True, smooth=False, name="ball")


def _sock():
    """The draped sock: rings along a path over the rim (a rotation-minimising frame keeps it from
    twisting), flattened against whatever it lies on, striped by arc length."""
    ang = SOCK_ANG
    rad = Vector((math.cos(ang), math.sin(ang), 0.0))
    tan = Vector((-math.sin(ang), math.cos(ang), 0.0))

    def P(rr, z, along=0.0):
        return rad * rr + tan * along + Vector((0, 0, z))
    rim_top = Z_TOP + RIM_R * 1.6
    ctrl = [P(1.25, 4.75), P(1.6, 5.3), P(1.95, rim_top + 0.22), P(2.34, rim_top - 0.04),
            P(wall_r(4.6) + 0.3, 4.55), P(wall_r(3.95) + 0.27, 3.95), P(wall_r(3.4) + 0.28, 3.32, 0.1),
            P(wall_r(3.2) + 0.25, 3.12, 0.62), P(wall_r(3.2) + 0.24, 3.16, 1.15), P(wall_r(3.3) + 0.23, 3.28, 1.55)]
    I_RIM, I_HEEL = 2, 6  # control points: over the rim, the heel
    # densely sampled Catmull-Rom path
    per = 5  # samples per control span
    pts = []
    c = [ctrl[0]] + ctrl + [ctrl[-1]]
    for i in range(1, len(c) - 2):
        for k in range(per):
            t = k / per
            p0, p1, p2, p3 = c[i - 1], c[i], c[i + 1], c[i + 2]
            pts.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    pts.append(ctrl[-1])
    # arc length
    s = [0.0]
    for a, b in zip(pts, pts[1:]):
        s.append(s[-1] + (b - a).length)
    L = s[-1]
    r0, squash, nseg = 0.4, 0.5, 12
    toe = 0.36
    s_rim, s_heel = s[per * I_RIM], s[per * I_HEEL]

    def radius(si):
        if si > L - toe:
            t = (si - (L - toe)) / toe
            return r0 * math.sqrt(max(1 - t * t, 0.0)) + 0.002
        if si < 0.3:  # the cuff stands open a touch wider
            return r0 * 1.08
        return r0 * (1 + 0.14 * max(0.0, 1 - abs(si - s_heel) / 0.35))  # the heel bulges
    # rotation-minimising frame
    T = [(pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized() for i in range(len(pts))]
    B1 = [(Vector((0, 0, 1)).cross(T[0])).normalized()]
    for i in range(1, len(pts)):
        b = B1[-1] - T[i] * B1[-1].dot(T[i])
        B1.append(b.normalized())
    bm = bmesh.new()
    rings = []
    for i, p in enumerate(pts):
        t = T[i]
        b1 = B1[i]
        b2 = t.cross(b1)
        # squash axis: away from the wall (radial) where it hangs, up where it crosses the rim
        radial = Vector((p.x, p.y, 0.0)).normalized()
        sq = radial - t * radial.dot(t)
        up = Vector((0, 0, 1)) - t * t.z
        w = min(sq.length / 0.7, 1.0)
        sq = (sq.normalized() * w + up.normalized() * (1 - w) * (1 if up.length > 1e-6 else 0))
        sq = sq.normalized() if sq.length > 1e-6 else b1
        r = radius(s[i])
        ring = []
        for k in range(nseg):
            a = math.tau * k / nseg
            d = b1 * math.cos(a) + b2 * math.sin(a)
            d = d - sq * d.dot(sq) * (1 - squash)
            ring.append(bm.verts.new(p + d * r))
        rings.append(ring)
    pals = []

    def ring_pal(si):
        if si < 0.42:
            return SOCK_W  # ribbed cuff
        if si > L - toe - 0.1:
            return SOCK_S  # toe
        if abs(si - s_heel) < 0.24:
            return SOCK_S  # heel
        # three broad stripes down the leg, between the rim and the heel
        for k in range(3):
            c = s_rim + 0.45 + k * 0.5
            if abs(si - c) < 0.11 and c < s_heel - 0.4:
                return SOCK_S
        return SOCK
    for i in range(len(rings) - 1):
        for k in range(nseg):
            bm.faces.new((rings[i][k], rings[i][(k + 1) % nseg], rings[i + 1][(k + 1) % nseg], rings[i + 1][k]))
            pals.append(ring_pal((s[i] + s[i + 1]) / 2))
    # cuff opening (dark inside) and the toe tip
    bm.faces.new(list(reversed(rings[0])))
    pals.append(SOCK_IN)
    tip = bm.verts.new(pts[-1] + T[-1] * 0.02)
    for k in range(nseg):
        bm.faces.new((rings[-1][k], rings[-1][(k + 1) % nseg], tip))
        pals.append(SOCK_S)
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("sock")
    bm.to_mesh(me)
    bm.free()
    pc = K.Piece(me, pals, outline=True, smooth=True, name="sock")
    pc.flat_faces = [len(pals) - nseg - 1]
    return pc


def build():
    p = [_bin()] + _stars()
    # crumpled paper heaped to the brim (the top ones peek over the rim)
    for i, (x, y, z, r) in enumerate(((-0.62, 0.5, 4.75, 0.66), (0.62, 0.6, 4.8, 0.6), (0.0, -0.75, 4.7, 0.6),
                                      (-1.0, -0.45, 4.65, 0.52), (1.0, -0.32, 4.6, 0.5), (-0.1, 0.15, 5.3, 0.58),
                                      (0.6, -0.15, 5.45, 0.44), (-0.65, -0.3, 5.42, 0.42))):
        pals = (NOTE, NOTE_D) if i == 4 else (PAPER, PAPER_D)
        p.append(_paper_ball((x, y, z), r, 11 + i, pals))
    # smaller, plainer balls round the edge fill the opening (none where the sock goes in)
    for k, deg in enumerate((-35, 5, 45, 85, 125, 165, 205, 245)):
        a = math.radians(deg)
        p.append(_paper_ball((1.4 * math.cos(a), 1.4 * math.sin(a), 4.72 + 0.1 * (k % 2)), 0.48, 40 + k, subdiv=1))
    # the one that missed
    p.append(_paper_ball((-1.55, -1.6, 0.4), 0.44, 7, squash=0.92))
    p.append(_sock())
    body, outline = K.finish(p, NAME, outline_width=OUTLINE)
    return [body, outline] + K.markers(NAME)
