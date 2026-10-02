"""
props/beachball.py - the BeachBall prop (ReplicatedStorage.MapMeshes.BeachBall): a classic six-panel
beach ball resting on the bedroom floor. See props/__init__.py for the conventions every prop follows.

One latitude/longitude sphere whose poles sit on a tilted axis (so the top cap and the curved gores
read from the front): six gores alternating red / white / yellow / white / blue / white, every gore
border a meridian of the mesh and the cap border one of its rings, so the colour edges are clean
curves. White caps at both poles, a little valve plug on a white gore near the top cap. The ball is
squashed a touch overall and flattened where it rests on the floor (a smooth blend, no crease for
the outline hull). Light / base / shade tones are cut along iso-lines of the surface normal; a
curved glossy highlight and a small dot sit on the upper front-left like the toys in the keyframe.
"""
import math
import bmesh
from mathutils import Matrix, Vector
import sockkit as K
from sockkit import hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "BeachBall"

# (lit top, base, shade) per panel colour
RED = (hexcol("beachball_red_light", "#FF6F5E"), hexcol("beachball_red", "#EB4339"), hexcol("beachball_red_dark", "#B92F2E"))
YEL = (hexcol("beachball_yellow_light", "#FFE071"), hexcol("beachball_yellow", "#FFC52E"), hexcol("beachball_yellow_dark", "#D9941C"))
BLU = (hexcol("beachball_blue_light", "#74A6F2"), hexcol("beachball_blue", "#3F7BDE"), hexcol("beachball_blue_dark", "#2C58B0"))
WHT = (hexcol("beachball_white_light", "#FFFFFC"), hexcol("beachball_white", "#F4EFE6"), hexcol("beachball_white_dark", "#C9C0D2"))
GLOSS = hexcol("beachball_gloss", "#FFFFFF")
VALVE = hexcol("beachball_valve", "#E9E3F0")
VALVE_D = hexcol("beachball_valve_dark", "#B8AEC6")
SEAM = hexcol("beachball_seam", "#3A2A48")   # thin ink ring round each cap

R = 2.0            # radius (fit 40 x 38 x 40: the squash takes the height to ~3.8)
SEG = 36           # meridians, 10 degrees apart
CAP = 0.27         # cap angular radius (rad)
SEAM_W = 0.035     # cap seam ring width (rad)
GORES = [RED, WHT, YEL, WHT, BLU, WHT]
GORE_EDGES = [0, 80, 120, 200, 240, 320, 360]   # degrees: the coloured gores are twice as wide as the white ones
TONE_CUTS = (-0.42, 0.62)   # normal z: shade / base / lit
TILT = 0.72        # the pole axis leans this far (rad) ...
TILT_DIR = 0.5     # ... toward this heading (rad from front -Y, + toward +X): the cap shows top front-right
GLOSS_DIR = Vector((-0.42, -0.62, 0.66))   # centre of the highlight streak (the red gore is turned under it)
FLAT_Z = -0.86     # (in radii) below this the ball flattens onto the floor
FLAT_K = 0.4       # how much of the height below FLAT_Z is kept
SQUASH = 0.995     # overall height squash


def _iso_cut(bm, vals, cuts):
    """Splits the faces of `bm` along the iso-lines vals == c for every c in `cuts` (vals: vert ->
    float, extended to the new verts), so a colour step drawn at c is a clean curve instead of a
    stair of whole faces. The surface itself is unchanged (new verts sit on existing edges)."""
    for c in cuts:
        for v in bm.verts:
            if abs(vals[v] - c) < 1e-5:
                vals[v] = c + 1e-5
        new = set()
        for e in list(bm.edges):
            a, b = e.verts
            va, vb = vals[a], vals[b]
            if (va - c) * (vb - c) < 0:
                _, nv = bmesh.utils.edge_split(e, a, (c - va) / (vb - va))
                vals[nv] = c
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


def _orient():
    """Local (pole on +Z) -> world rotation: spin round the pole, then lean the pole. The spin turns
    the middle of the red gore (local heading 40 degrees) under the highlight."""
    lean_axis = Vector((math.cos(TILT_DIR), math.sin(TILT_DIR), 0))  # perpendicular to the lean heading
    lean = Matrix.Rotation(TILT, 4, lean_axis)
    g = lean.inverted() @ GLOSS_DIR
    spin = math.atan2(g.y, g.x) - math.radians((GORE_EDGES[0] + GORE_EDGES[1]) / 2)
    return lean @ Matrix.Rotation(spin, 4, "Z")


def _squash(p):
    """World-space shape tweak on a ball of radius R centred on the origin: a touch flatter overall
    and a soft flat patch where it rests on the floor (smooth max -> no crease)."""
    x, y, z = p
    zr = z / R
    flat = FLAT_Z + (zr - FLAT_Z) * FLAT_K
    k = 0.05
    zr = 0.5 * (zr + flat + math.sqrt((zr - flat) ** 2 + k * k)) - 0.5 * k  # smooth max(zr, flat)
    bulge = 1 + 0.025 * max(0.0, 1 - ((zr + 0.35) / 0.9) ** 2)  # the sides give a little under the weight
    return Vector((x * bulge, y * bulge, zr * R * SQUASH))


def _lift(p):
    """Puts the squashed ball on the floor."""
    return p + Vector((0, 0, -_squash(Vector((0, 0, -R)))[2]))


def _ball():
    c1 = CAP + SEAM_W
    lats = [CAP * 0.5, CAP, c1]
    n_mid = 14
    for i in range(1, n_mid):
        lats.append(c1 + (math.pi - 2 * c1) * i / n_mid)
    lats += [math.pi - c1, math.pi - CAP, math.pi - CAP * 0.5]
    bm = bmesh.new()
    region = bm.faces.layers.int.new("region")  # 0..5 = gore, 6 = cap, 7 = seam
    top = bm.verts.new((0, 0, 1))
    bot = bm.verts.new((0, 0, -1))
    rings = []
    for t in lats:
        rings.append([bm.verts.new((math.sin(t) * math.cos(j / SEG * math.tau), math.sin(t) * math.sin(j / SEG * math.tau),
                                    math.cos(t))) for j in range(SEG)])

    def tag(f, ring_i):
        if ring_i < 2 or ring_i >= len(lats) - 1:  # inside a cap
            f[region] = 6
        elif ring_i == 2 or ring_i == len(lats) - 2:  # the thin ring round a cap
            f[region] = 7
        else:
            c = f.calc_center_median()
            a = math.degrees(math.atan2(c.y, c.x) % math.tau)
            f[region] = max(i for i in range(6) if GORE_EDGES[i] <= a)

    for j in range(SEG):
        k = (j + 1) % SEG
        tag(bm.faces.new((top, rings[0][j], rings[0][k])), 0)
        tag(bm.faces.new((bot, rings[-1][k], rings[-1][j])), len(lats))
        for i in range(len(lats) - 1):
            tag(bm.faces.new((rings[i][j], rings[i + 1][j], rings[i + 1][k], rings[i][k])), i + 1)
    rot = _orient()
    for v in bm.verts:
        v.co = _lift(_squash(rot @ (v.co * R)))
    bm.normal_update()
    vals = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, vals, TONE_CUTS)
    pal = []
    for f in bm.faces:
        if f[region] == 7:
            pal.append(SEAM)
            continue
        cols = WHT if f[region] == 6 else GORES[f[region]]
        nz = sum(vals[v] for v in f.verts) / len(f.verts)
        pal.append(cols[0] if nz > TONE_CUTS[1] else (cols[2] if nz < TONE_CUTS[0] else cols[1]))
    return K.Piece(K._bm_to_mesh(bm, "ball"), pal, True, True, "ball")


def _surface(d, lift=0.0):
    """World point on the ball's surface in unit direction `d` (of the unsquashed ball), lifted."""
    return _lift(_squash(d.normalized() * (R + lift)))


def _gloss(center_dir, a, b, bend, roll=0.0, lift=0.025, nu=10, nv=4, name="gloss"):
    """A curved highlight sheet on the ball: an ellipse (half-axes a, b in radians of arc) round
    `center_dir`, its long axis turned `roll` from level (+ = right end up) and bent by `bend` (the
    ends curl away from the ball's outline: a crescent that follows its curve)."""
    d0 = center_dir.normalized()
    e1 = Vector((0, 0, 1)).cross(d0).normalized()   # level, along the latitude
    e2 = d0.cross(e1)                                # toward the top
    t1 = e1 * math.cos(roll) + e2 * math.sin(roll)
    t2 = d0.cross(t1)
    bm = bmesh.new()

    def vert(r, th):
        u = a * r * math.cos(th)
        w = b * r * math.sin(th) - bend * (u / max(a, 1e-6)) ** 2   # the ends curl down: a crescent
        ang = math.hypot(u, w)
        q = d0 if ang < 1e-9 else d0 * math.cos(ang) + (t1 * u + t2 * w) / ang * math.sin(ang)
        return bm.verts.new(_surface(q, lift * (1 - 0.5 * r * r)))
    mid = vert(0.0, 0.0)
    ring = [[vert(i / nv, j / (nu * 2) * math.tau) for j in range(nu * 2)] for i in range(1, nv + 1)]
    n = nu * 2
    for j in range(n):
        bm.faces.new((mid, ring[0][j], ring[0][(j + 1) % n]))
    for i in range(nv - 1):
        for j in range(n):
            bm.faces.new((ring[i][j], ring[i + 1][j], ring[i + 1][(j + 1) % n], ring[i][(j + 1) % n]))
    bm.normal_update()
    if sum(f.normal.dot(f.calc_center_median() - Vector((0, 0, R))) for f in bm.faces) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    return K.Piece(K._bm_to_mesh(bm, name), GLOSS, False, True, name)


def _valve():
    """A little plug just below the top cap, on the white gore opposite the red one (round the back,
    so it doesn't read as an eye next to the highlight)."""
    rot = _orient()
    th, ph = CAP + SEAM_W + 0.15, math.radians(220)
    d = rot @ Vector((math.sin(th) * math.cos(ph), math.sin(th) * math.sin(ph), math.cos(th)))
    base = _surface(d, -0.02)
    n = (_surface(d, 0.1) - base).normalized()
    m = Matrix.Translation(base) @ n.to_track_quat("Z", "Y").to_matrix().to_4x4()
    return [K.cylinder(VALVE, 0.11, 0.08, m @ Matrix.Translation((0, 0, 0.02)), seg=12, name="valve"),
            K.cylinder(VALVE_D, 0.055, 0.02, m @ Matrix.Translation((0, 0, 0.065)), seg=10, outline=False, name="valve_top")]


def build():
    p = [_ball()]
    p += _valve()
    # glossy highlight: a curved streak and a small dot, upper front-left (the keyframe's light)
    p.append(_gloss(GLOSS_DIR, 0.34, 0.075, -0.07, roll=0.75, name="gloss"))
    p.append(_gloss(GLOSS_DIR + Vector((-0.2, 0.0, -0.3)), 0.05, 0.045, 0.0, nu=6, nv=2, name="gloss_dot"))
    body, outline = K.finish(p, NAME, outline_width=0.075)
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission", "visible_volume_scatter"):
        if hasattr(outline, attr):  # preview only: the hull must not block light (it doesn't in Roblox)
            setattr(outline, attr, False)
    return [body, outline] + K.markers(NAME)
