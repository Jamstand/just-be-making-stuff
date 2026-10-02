"""
props/teddy.py - the Teddy prop (ReplicatedStorage.MapMeshes.Teddy). See props/__init__.py for
the conventions every prop follows.

The reddish-brown teddy from the bedroom keyframe, sitting upright with its legs stretched forward
and splayed in a wide V: a big round head (wider than tall) on a short, chibi body, round ears with
D-shaped lighter inner ears (thin dark edge), a protruding tan muzzle a little under half the head's
width (flat front, steep sides, so its ink hugs the tan edge) with a dark rounded nose and a short,
faint, almost straight mouth line low on it, small black bead eyes, a pear-shaped body with an
egg-shaped lighter belly starting just under the chin, chubby arms that hang clear of the body (ink
along their inner edge) with the paws resting on the floor beside the hips, and feet that are just
the rounded ends of the legs, turned forward and outward, with lighter oval pads on the soles.
The belly, inner ears and pads are thin sheets laid onto their part's surface (an ellipsoid would
sink into the flat front or poke out of a curved one). Fur tones are cut along smooth iso-lines of
the surface normal, so every lit / shaded area is one clean shape rather than a stair of faces.
Colours were sampled from docs/concept/bedroom_keyframe.png.
"""
import math
import bmesh
import bpy
import sockkit as K
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Teddy"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"teddy_pad": "felt", "teddy_ear_in": "felt", "teddy_nose": "plastic"}

F_BASE = hexcol("teddy_fur", "#AA4A22")       # most of the fur (art: #AE4A21)
F_TOP = hexcol("teddy_fur_top", "#BE5824")    # lit, top-facing fur (art: head top #C15923)
F_SHADE = hexcol("teddy_fur_shade", "#8A3A1C")  # undersides / shadowed sides (art: #91391F)
TAN = hexcol("teddy_tan", "#E0914C")          # muzzle / belly
TAN_EAR = hexcol("teddy_ear_in", "#D9844D")   # inner ears
PAD = hexcol("teddy_pad", "#E8A262")          # paw pads
NOSE = hexcol("teddy_nose", "#3A2323")
EYE = hexcol("teddy_eye", "#231517")
MOUTH = hexcol("teddy_mouth", "#8A4632")      # a soft muzzle-shadow line, not a drawn grin
EAR_RIM = hexcol("teddy_ear_rim", "#4A2018")  # thin dark edge round the inner ear
INK = hexcol("teddy_ink", "#1E120E")          # drawn ink lines: as dark as the hull renders

FUR_CUTS = (-0.45, 0.78)        # normal.z thresholds: shaded underside / base / lit top
FUR_CUTS_SMALL = (-0.45, 0.9)   # small round parts: only the polar cap is lit


def _fur(nz):
    if nz > 0.78:
        return F_TOP
    if nz < -0.45:
        return F_SHADE
    return F_BASE


def _fur_small(nz):
    """_fur for the small round parts (feet, paws, shoulder caps): only the polar cap gets the lit
    tone, so it reads as a round highlight."""
    if nz > 0.9:
        return F_TOP
    if nz < -0.45:
        return F_SHADE
    return F_BASE


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


def _iso_piece(bm, pal, cuts, name, outline=True):
    """bmesh -> Piece coloured per face by pal(mean smooth-normal z), cut along `cuts` first."""
    bm.normal_update()
    vals = {v: v.normal.z for v in bm.verts}
    _iso_cut(bm, vals, cuts)
    fp = [pal(sum(vals[v] for v in f.verts) / len(f.verts)) for f in bm.faces]
    return K.Piece(K._bm_to_mesh(bm, name), fp, outline, True, name)


def _blob(fn, pal, seg=24, rings=14, name="blob", outline=True, cuts=FUR_CUTS):
    """A UV sphere whose unit-sphere vertices are mapped through fn(Vector) -> world position.
    `pal` is a palette index, or pal(normal z) -> index, coloured with clean bands (see _iso_piece)."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
    for v in bm.verts:
        v.co = Vector(fn(v.co.copy()))
    if callable(pal):
        return _iso_piece(bm, pal, cuts, name, outline)
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline, True, name)


def _fur_piece(piece, pal=_fur, cuts=FUR_CUTS):
    """Re-colours a tube piece by smooth normal like the blobs (lit top / base / shaded underside)."""
    bm = bmesh.new()
    bm.from_mesh(piece.mesh)
    out = _iso_piece(bm, pal, cuts, piece.name, piece.outline)
    bpy.data.meshes.remove(piece.mesh)
    return out


def _decal(target, center, semi, pal, offset=0.05, rings=10, seg=36, name="decal", widen_low=0.0):
    """A thin oval sheet hugging the FRONT of `target` (a Piece): an ellipse in the XZ plane
    (`center` = (x, z), `semi` = (ax, az)) projected along +Y onto the mesh, then lifted `offset`
    toward the viewer (a little less at the rim, so it reads as a soft raised patch).
    `widen_low` widens the lower half (an egg shape, wider at the bottom)."""
    me = target.mesh
    bvh = BVHTree.FromPolygons([v.co.copy() for v in me.vertices], [tuple(p.vertices) for p in me.polygons])
    bm = bmesh.new()

    def vert(r, a):
        x = center[0] + semi[0] * (1 + widen_low * max(0.0, -math.sin(a))) * r * math.cos(a)
        z = center[1] + semi[1] * r * math.sin(a)
        hit = bvh.ray_cast(Vector((x, -50.0, z)), Vector((0, 1, 0)))[0]
        y = hit.y if hit is not None else 0.0
        return bm.verts.new((x, y - offset * (1 - 0.45 * r * r), z))
    mid = vert(0.0, 0.0)
    ringv = [[vert(i / rings, j / seg * math.tau) for j in range(seg)] for i in range(1, rings + 1)]
    for j in range(seg):
        bm.faces.new((mid, ringv[0][(j + 1) % seg], ringv[0][j]))
    for i in range(rings - 1):
        a, b = ringv[i], ringv[i + 1]
        for j in range(seg):
            bm.faces.new((a[j], a[(j + 1) % seg], b[(j + 1) % seg], b[j]))
    bm.normal_update()
    if sum(f.normal.y for f in bm.faces) > 0:  # face the viewer (-Y)
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    return K.Piece(K._bm_to_mesh(bm, name), pal, False, True, name)


def _ellipsoid(center, axes, rot=(0, 0, 0)):
    m = M(center, rot=rot, scale=axes)
    return lambda p: m @ p


def _flatten_bottom(w, at=-0.45, k=0.42):
    return w if w > at else at + (w - at) * k


# ---------------------------------------------------------------- shapes
# a short, chibi body: chin-to-seat about 1.1x the head's height (the art), arms about as long
BODY_H = 1.65                       # body z scale
ARM_R, LEG_R = 0.43, 0.44           # limb tube radii
HEAD_C = Vector((0, 0.05, 3.9))
HEAD_A = (1.45, 1.25, 1.22)


def _head(p):
    u, v, w = p
    cheek = 1 + 0.07 * max(0.0, -w)  # a touch wider at the cheeks
    return HEAD_C + Vector((u * HEAD_A[0] * cheek, v * HEAD_A[1], w * HEAD_A[2]))


def _head_point(az, el, out=0.0):
    d = Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))
    return HEAD_C + Vector((d.x * HEAD_A[0], d.y * HEAD_A[1], d.z * HEAD_A[2])) * (1 + out), d


def _body(p):
    u, v, w = p
    w2 = _flatten_bottom(w)
    pear = 1 + 0.16 * (-w)            # wider hips, narrower shoulders
    belly = 1 + 0.12 * (1 - w * w) if v < 0 else 1.0  # rounder tummy
    return (u * 1.16 * pear, 0.28 + v * 1.02 * (1 + 0.08 * (-w)) * belly, (w2 + 0.682) * BODY_H)


def _patch(place, axes, center, semi, lift, pal, name, seg=20, rings=3):
    """A thin oval sheet lying on the FRONT (-Y) of an ellipsoid with semi-axes `axes` in its local
    frame (`place(x, y, z)` -> world): an ellipse (`center` = (x, z), `semi` = (sx, sz)) whose points
    sit on the ellipsoid surface, lifted `lift` toward the viewer (less at the rim). Used for the
    inner ears and the foot pads, so they hug their curved part instead of poking out of it."""
    ax, ay, az = axes
    bm = bmesh.new()

    def vert(r, t):
        x = center[0] + semi[0] * r * math.cos(t)
        z = center[1] + semi[1] * r * math.sin(t)
        q = max(0.0, 1 - (x / ax) ** 2 - (z / az) ** 2)
        y = -ay * math.sqrt(q) - lift * (1 - 0.4 * r * r)
        return bm.verts.new(place(x, y, z))
    mid = vert(0.0, 0.0)
    ring = [[vert(i / rings, j / seg * math.tau) for j in range(seg)] for i in range(1, rings + 1)]
    for j in range(seg):
        bm.faces.new((mid, ring[0][(j + 1) % seg], ring[0][j]))
    for i in range(rings - 1):
        r0, r1 = ring[i], ring[i + 1]
        for j in range(seg):
            bm.faces.new((r0[j], r0[(j + 1) % seg], r1[(j + 1) % seg], r1[j]))
    bm.normal_update()
    # face away from the part's centre (its local -Y), whatever way the part is turned
    out = Vector(place(0, -1, 0)) - Vector(place(0, 0, 0))
    if sum(f.normal.dot(out) for f in bm.faces) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    return K.Piece(K._bm_to_mesh(bm, name), pal, False, True, name)


def _ear(side):
    """-> (ear shape fn, inner-ear patch, its dark rim). The inner ear lies on the ear's front face,
    low and toward the head, so the head's outline clips it into the art's D shape; a slightly
    larger dark sheet under it reads as the thin ink edge the art draws round it."""
    c = Vector((side * 1.14, 0.4, HEAD_C.z + 0.95))
    a = side * -0.35  # tilt the ear outward a little
    axes = (0.48, 0.26, 0.46)

    def place(x, y, z):
        x, z = x * math.cos(a) - z * math.sin(a), x * math.sin(a) + z * math.cos(a)
        return (c.x + x, c.y + y, c.z + z)

    def ear(p):
        return place(p.x * axes[0], p.y * axes[1], p.z * axes[2])
    mid = (-side * 0.03, -0.06)  # toward the head, and down
    return (ear, _patch(place, axes, mid, (0.34, 0.30), 0.04, TAN_EAR, "ear_in"),
            _patch(place, axes, mid, (0.365, 0.325), 0.018, EAR_RIM, "ear_rim"))


MUZ_X = 0.64                       # muzzle half-width: a little under half the head's width
MUZ_Y, MUZ_Z = 0.5, 0.56           # half-depth, half-height
MUZ_C = Vector((0, -0.9, HEAD_C.z - 0.56))
MUZ_FLAT = 0.5                     # < 1: flatter front, steeper sides (the ink hugs the tan edge)


def _muzzle(p):
    """A flat-fronted, rounded pad whose sides run straight back into the head (a short can, not
    an egg): seen from the front its silhouette IS the edge where the tan meets the fur, so the
    outline sits right on the tan edge instead of floating outside it over a strip of cheek fur."""
    u, v, w = p
    if v < 0:
        y = -MUZ_Y * abs(v) ** MUZ_FLAT
        x, z = u * MUZ_X, w * MUZ_Z
    else:
        r = math.hypot(u, w)
        k = (1.0 if v < 0.85 else max(0.0, (1 - v) / 0.15)) / max(r, 1e-6)
        x, z = u * k * MUZ_X, w * k * MUZ_Z
        y = MUZ_Y * 1.3 * v
    z += 0.05 * (x / MUZ_X) ** 2          # rounder top corners
    return (x, MUZ_C.y + y, MUZ_C.z + z)


def _muzzle_front(x, z, lift=0.0):
    """Point on the muzzle's front surface at (x, z)."""
    dx, dz = x / MUZ_X, (z - MUZ_C.z) / MUZ_Z
    s = max(0.0, 1 - dx * dx - dz * dz)
    return Vector((x, MUZ_C.y - MUZ_Y * s ** (MUZ_FLAT / 2) - lift, z))


def _inside_head(q):
    w = (q.z - HEAD_C.z) / HEAD_A[2]
    cheek = 1 + 0.07 * max(0.0, -w)
    return (q.x / (HEAD_A[0] * cheek)) ** 2 + ((q.y - HEAD_C.y) / HEAD_A[1]) ** 2 + w * w < 1.0


def _muzzle_ink():
    """Points of a thin ink line on the muzzle's left, bottom and right edges, right where its side
    wall disappears into the head (the art draws the line there, and none along the top)."""
    pts = []
    n = 13
    for i in range(n):
        th = math.radians(25 - 230 * i / (n - 1))       # right side, round the bottom, left side
        x = MUZ_X * math.cos(th)
        z = MUZ_C.z + MUZ_Z * math.sin(th) + 0.05 * math.cos(th) ** 2
        y = MUZ_C.y - 0.1
        while y < MUZ_C.y + MUZ_Y * 1.3 and not _inside_head(Vector((x, y, z))):
            y += 0.01
        out = Vector((math.cos(th) / MUZ_X, 0, math.sin(th) / MUZ_Z)).normalized()
        pts.append(tuple(Vector((x, y - 0.03, z)) + out * 0.042))
    return pts


def _nose(p):
    u, v, w = p
    x, y, z = u * 0.26, v * 0.16, w * 0.175
    x *= 1 - 0.5 * max(0.0, -w) - 0.12 * w  # rounded triangle, point down
    top = _muzzle_front(0, MUZ_C.z + 0.33)
    return (x, top.y + 0.04 + y, top.z + z)


def _camera_only_outline(outline):
    """Preview only (Cycles ray visibility, not exported): the hull is seen by the camera but does
    not block bounce light, as in Roblox - otherwise previews show dark patches in the neck."""
    for attr in ("visible_shadow", "visible_diffuse", "visible_glossy", "visible_transmission",
                 "visible_volume_scatter"):
        if hasattr(outline, attr):
            setattr(outline, attr, False)


def build():
    body = _blob(_body, _fur, seg=26, rings=14, name="body")
    p = [_blob(_head, _fur, seg=26, rings=16, name="head"),
         body,
         # egg-shaped belly from just under the chin, wider low between the legs
         _decal(body, (0, 1.42), (0.72, 0.98), TAN, name="belly", widen_low=0.16, rings=6, seg=32),
         _blob(_muzzle, TAN, seg=20, rings=12, name="muzzle"),
         _blob(_nose, NOSE, seg=10, rings=7, outline=False, name="nose")]
    # a short, faint, almost straight mouth line low on the muzzle, under the nose
    mz = MUZ_C.z - 0.36
    pts = [_muzzle_front(x, mz - 0.008 * (1 - (x / 0.12) ** 2), 0.0) for x in (-0.12, 0.0, 0.12)]
    p.append(K.tube(MOUTH, pts, radius=0.018, res=2, bevel_res=0, outline=False, name="mouth"))
    ink = _muzzle_ink()
    radii = [0.2, 0.55, 0.85] + [1.0] * (len(ink) - 6) + [0.85, 0.55, 0.2]
    p.append(K.tube(INK, ink, radius=0.042, radii=radii, res=2, bevel_res=1, outline=False, name="muzzle_ink"))
    for side in (-1, 1):
        ear, inner, rim = _ear(side)
        p.append(_blob(ear, _fur_small, seg=14, rings=9, name="ear", cuts=FUR_CUTS_SMALL))
        p += [inner, rim]
        # small bead eyes
        pos, d = _head_point(side * 0.38, 0.09)
        p.append(K.sphere(EYE, 1.0, M(pos - d * 0.05, rot=(-0.09, 0, side * 0.38), scale=(0.175, 0.11, 0.2)),
                          seg=10, rings=7, outline=False, name="eye"))
        # small soft highlight on the upper-inner edge of the bead
        p.append(K.sphere(K.WHITE, 0.028, M(pos + d * 0.04 + Vector((-side * 0.055, -0.01, 0.09))),
                          seg=6, rings=4, outline=False, name="glint"))
        # arm hanging at the side, standing clear of the body (so the hull draws its inner edge),
        # paw resting on the floor beside the hip; its top starts inside the body under the chin and
        # is capped with a ball, so the shoulder reads as one round curve
        arm = [Vector((side * 0.84, 0.02, 2.32)), Vector((side * 1.3, -0.24, 1.86)), Vector((side * 1.52, -0.54, 1.2)),
               Vector((side * 1.6, -0.84, 0.66))]
        radii = [0.8, 0.95, 1.03, 1.05]
        p.append(_fur_piece(K.tube(F_BASE, [tuple(q) for q in arm], radius=ARM_R, radii=radii, res=5, bevel_res=3,
                                   name="arm")))
        p.append(_blob(_ellipsoid(arm[0], (ARM_R * radii[0],) * 3), _fur_small, seg=12, rings=7, name="shoulder",
                       cuts=FUR_CUTS_SMALL))
        p.append(_blob(_ellipsoid(arm[3] + Vector((side * 0.02, -0.08, -0.1)), (0.47, 0.5, 0.47)), _fur_small,
                       seg=14, rings=8, name="paw", cuts=FUR_CUTS_SMALL))
        # ink along the arm's inner edge, under the chin down to the paw: the art draws a clear line
        # between arm and belly (tapered at both ends like a brush stroke)
        ink = []
        for i in range(1, 4):
            for t in (0.0, 0.5) if i < 3 else (0.0, 0.5, 1.0):
                q0, q1 = arm[i - 1], arm[i]
                c = q0.lerp(q1, t)
                r = ARM_R * (radii[i - 1] + (radii[i] - radii[i - 1]) * t)
                n = Vector((-side * 0.95, -0.32, 0.0)).normalized()   # the inner silhouette, seen from the front
                ink.append(tuple(c + n * (r + 0.03)))
        ink = ink[1:]
        p.append(K.tube(INK, ink, radius=0.045, radii=[0.3, 0.8, 1.0, 1.0, 1.0, 0.6][:len(ink)], res=2,
                        bevel_res=1, outline=False, name="arm_ink"))
        # leg stretched forward and splayed about 40 degrees outward; the foot is the leg's rounded,
        # upturned end, its sole (and pad) facing forward and outward
        spread = 0.7
        hip = Vector((side * 0.6, -0.08, LEG_R))
        dirn = Vector((side * math.sin(spread), -math.cos(spread), 0))
        end = hip + dirn * 1.55
        leg = [tuple(hip), tuple(hip + dirn * 0.75 + Vector((0, 0, 0.01))), tuple(end)]
        p.append(_fur_piece(K.tube(F_BASE, leg, radius=LEG_R, radii=[1.0, 0.97, 0.95], res=5, bevel_res=3,
                                   name="leg")))
        foot_c = end + dirn * 0.1 + Vector((0, 0, 0.08))
        foot_axes = (0.49, 0.38, 0.52)
        foot_m = M(foot_c, rot=(0, 0, side * spread))
        p.append(_blob(_ellipsoid(foot_c, foot_axes, rot=(0, 0, side * spread)), _fur_small, seg=14, rings=9, name="foot",
                       cuts=FUR_CUTS_SMALL))
        # oval pad on the sole, hugging the foot's curve (about 65% of the sole)
        p.append(_patch(lambda x, y, z: tuple(foot_m @ Vector((x, y, z))), foot_axes, (0.0, 0.02), (0.33, 0.36),
                        0.03, PAD, "pad", seg=18, rings=3))
    teddy, outline = K.finish(p, "Teddy", outline_width=0.095)
    _camera_only_outline(outline)
    return [teddy, outline] + K.markers("Teddy")
