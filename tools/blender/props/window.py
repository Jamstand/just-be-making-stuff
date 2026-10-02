"""
props/window.py - the Window prop (ReplicatedStorage.MapMeshes.Window): the round porthole above the
bed. See props/__init__.py for the conventions every prop follows.

Art (docs/concept/bedroom_keyframe.png, top centre): a thick, rounded plum-maroon wood ring frame
(lighter where its inner bevel rolls into the opening), drawn low-poly - ring and reveal show flat
facets round the circle - a deep reveal that the moonlight paints a pale lavender, a dark-blue night
sky with a tiny cyan star, and a big pale cream crescent moon (opening to the upper right, its lower
horn curling up toward 4 o'clock) with three soft tan craters. Ink lines on the ring's outer and inner edges and
round the moon.

Wall-mounted: the back is flat on the wall at y = 0, the front faces -Y; origin = bottom centre of
the back. 6 units across, 0.92 deep (Map.luau fits it into 64 x 64 x 10 -> about 57 studs wide).
`MoonGlow` is the crescent on its own, untextured: the game makes it glowing Neon in the moon colour
(Map.luau GLOW_PARTS.MoonGlow) and hangs the moon light on it; its ink outline stays in the hull.
"""
import math
import bmesh
import bpy
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Window"

# texture classes for tools/blender/texturing.py where the colour names alone guess wrong
MATERIALS = {"window_sky": "painted"}
EXPORT_DIR = "map"

# colours sampled from the keyframe (ring lit by the lamp, reveal and sky lit by the moon)
# the ring is a deeper plum-maroon brown than the orange furniture (art: #582824 lamp side, #6E3C45
# bottom), lifted out of the night by the same amount as the other props
RING = hexcol("window_wood", "#7E3430")          # ring front face: dark warm wood
RING_L = hexcol("window_wood_light", "#A04E40")  # inner bevel rolling into the opening, lit tops
RING_D = hexcol("window_wood_dark", "#5A2526")   # outer rim, undersides
REVEAL = hexcol("window_reveal", "#B0AFCB")      # the deep reveal, moonlit (pale lavender)
REVEAL_D = hexcol("window_reveal_dark", "#8E8EB5")
SKY = hexcol("window_sky", "#3C5496")            # night sky
CRATER = hexcol("window_crater", "#E8D8AE")      # soft tan craters
STAR = hexcol("window_star", "#8FD4EC")          # the little cyan star (art #8DD0E3)
MOON = hexcol("window_moon", "#F7EDCF")          # = Map.luau C.MoonGlow (247, 237, 207): previews only

R_OUT = 3.0     # outer radius of the ring
R_IN = 2.25     # radius of the opening (reveal)
CZ = R_OUT      # centre height (origin = bottom of the back face)
DEPTH = 0.92    # wall to ring front (+ the hull = 1.07: Map.luau fits 64 x 64 x 10 -> ~57 studs wide)
SKY_Y = -0.04   # front face of the sky disc (deep in the reveal)
MOON_Y0, MOON_Y1 = -0.07, -0.31  # moon back / front
SEG = 28        # segments round the ring: the art draws the ring and reveal with flat facets
OUTLINE = 0.075
MOON_LINE = 0.045  # the art inks the moon thinner than the frame

# crescent (x right, z up, relative to the window centre): outer disc A minus the bite B, with
# rounded tips - fitted to the moon in the keyframe (opening to the upper right)
A_C, A_R = (-0.08, 0.42), 1.6
B_C, B_R = (0.745, 0.858), 1.256
TIP_R = 0.03       # the horns taper to fine, almost sharp points as in the art
TIP_MIN = 0.006    # smallest tip rounding (the eroded outlines of the rounded rim and the ink copy)
MOON_BEVEL = 0.05  # radius of the moon's rounded front / back rim


def _lathe(profile, segs, name):
    """Revolves a closed loop of (r, y) profile points round the window axis (parallel to Y through
    (0, *, CZ))."""
    bm = bmesh.new()
    rings = []
    for i in range(segs):
        a = i / segs * math.tau
        ca, sa = math.cos(a), math.sin(a)
        rings.append([bm.verts.new((r * ca, y, CZ + r * sa)) for r, y in profile])
    n = len(profile)
    for i in range(segs):
        r0, r1 = rings[i], rings[(i + 1) % segs]
        for j in range(n):
            k = (j + 1) % n
            bm.faces.new((r0[j], r0[k], r1[k], r1[j]))
    bm.normal_update()
    # make every face point out of the solid: the front-most face must look toward -Y
    front = min(bm.faces, key=lambda f: f.calc_center_median().y)
    if front.normal.y > 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return me


def _arc(cx, cy, r, a0, a1, n):
    return [(cx + r * math.cos(a0 + (a1 - a0) * k / n), cy + r * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]


def _circle_hits(c0, r0, c1, r1):
    dx, dy = c1[0] - c0[0], c1[1] - c0[1]
    d = math.hypot(dx, dy)
    a = (r0 * r0 - r1 * r1 + d * d) / (2 * d)
    h = math.sqrt(max(r0 * r0 - a * a, 0.0))
    mx, my = c0[0] + a * dx / d, c0[1] + a * dy / d
    return [(mx - h * dy / d, my + h * dx / d), (mx + h * dy / d, my - h * dx / d)]


def _ang(c, p):
    return math.atan2(p[1] - c[1], p[0] - c[0])


ARC_N = 40  # segments along each of the crescent's two arcs


def _crescent(erode=0.0):
    """2D outline (x, z) of the crescent, counter-clockwise, tips rounded with radius TIP_R, plus its
    cap faces as index tuples: a quad strip between the outer and inner arcs and a small fan polygon
    at each tip (a clean fill - one big concave n-gon breaks the outline hull).
    erode > 0: the same crescent shrunk inward by `erode` (disc A smaller, the bite B bigger, the tips
    rounded with what is left of TIP_R) - exact offsets, with the same point count at every erode."""
    a_r, b_r = A_R - erode, B_R + erode
    tip = max(TIP_R - erode, TIP_MIN)
    # centres of the tip-rounding circles: inside A, outside B
    caps = _circle_hits(A_C, a_r - tip, B_C, b_r + tip)
    caps.sort(key=lambda p: -p[1])  # upper tip first
    pts = []
    up, lo = caps
    # outer arc on A from the upper tip, counter-clockwise (through the left) to the lower tip
    a0 = _ang(A_C, up)
    a1 = _ang(A_C, lo)
    while a1 < a0:
        a1 += math.tau
    pts += _arc(A_C[0], A_C[1], a_r, a0, a1, ARC_N)
    # lower tip cap: from the A tangent point round the outside of the tip to the B tangent point
    t0 = _ang(lo, (lo[0] + (lo[0] - A_C[0]), lo[1] + (lo[1] - A_C[1])))
    t1 = _ang(lo, (lo[0] + (B_C[0] - lo[0]), lo[1] + (B_C[1] - lo[1])))
    while t1 < t0:
        t1 += math.tau
    pts += _arc(lo[0], lo[1], tip, t0, t1, 5)[1:-1]
    # inner arc on B (the bite), clockwise back to the upper tip
    b0 = _ang(B_C, lo)
    b1 = _ang(B_C, up)
    while b1 > b0:
        b1 -= math.tau
    pts += _arc(B_C[0], B_C[1], b_r, b0, b1, ARC_N)
    t0 = _ang(up, (up[0] + (B_C[0] - up[0]), up[1] + (B_C[1] - up[1])))
    t1 = _ang(up, (up[0] + (up[0] - A_C[0]), up[1] + (up[1] - A_C[1])))
    while t1 < t0:
        t1 += math.tau
    pts += _arc(up[0], up[1], tip, t0, t1, 5)[1:-1]
    n = ARC_N
    inner = n + 5  # index of the inner arc's first point (at the lower tip)
    faces = [(i, i + 1, inner + n - i - 1, inner + n - i) for i in range(n)]
    faces.append(tuple(range(n, inner + 1)))                              # lower tip
    faces.append((inner + n,) + tuple(range(inner + n + 1, len(pts))) + (0,))  # upper tip
    return pts, faces


def _slab(pts, y0, y1, bevel, segs, name, cap=None):
    """Extrudes a 2D (x, z) outline (window-centre relative) from y0 (back) to y1 (front) and rounds
    its rim with an angle-limited bevel. `cap`: the front / back faces as index tuples into pts
    (default: one n-gon)."""
    bm = bmesh.new()
    back = [bm.verts.new((x, y0, CZ + z)) for x, z in pts]
    front = [bm.verts.new((x, y1, CZ + z)) for x, z in pts]
    n = len(pts)
    for idx in (cap or [tuple(range(n))]):
        bm.faces.new([front[i] for i in idx])
        bm.faces.new([back[i] for i in reversed(idx)])
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((back[i], back[j], front[j], front[i]))
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    K.link(obj)
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = bevel
    mod.segments = segs
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(40)
    mod.harden_normals = False
    return K.bake_object(obj)


def _moon_mesh(erode, name, segs=4):
    """The crescent as a slab from MOON_Y0 (back) to MOON_Y1 (front) whose front and back rims are
    rounded with radius MOON_BEVEL: a loft of exactly eroded crescent outlines (a Bevel modifier
    clamps its width to the tiny tips - for the whole mesh). erode > 0 gives the same moon shrunk
    by `erode` everywhere (for the finer ink line: the hull then inflates it by OUTLINE)."""
    r, t = MOON_BEVEL, MOON_Y0 - MOON_Y1
    rr = r - erode
    prof = [(r - rr * math.sin(a), r - rr * math.cos(a)) for a in [k / segs * math.pi / 2 for k in range(segs + 1)]]
    prof += [(r - rr * math.cos(a), t - r + rr * math.sin(a)) for a in [k / segs * math.pi / 2 for k in range(segs + 1)]]
    bm = bmesh.new()
    layers = []
    cap = None
    for o, s in prof:  # o = inset from the outline, s = depth in front of the back face
        pts, cap = _crescent(o)
        layers.append([bm.verts.new((x, MOON_Y0 - s, CZ + z)) for x, z in pts])
    n = len(layers[0])
    for la, lb in zip(layers, layers[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((la[i], la[j], lb[j], lb[i]))
    for idx in cap:
        bm.faces.new([layers[-1][i] for i in idx])
        bm.faces.new([layers[0][i] for i in reversed(idx)])
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return me


def _blob(cx, cz, rx, rz, tilt, y, pal, name, n=7, wobble=0.12):
    """A flat, slightly irregular disc (crater / star) lying on a surface whose front is at y."""
    pts = []
    for k in range(n):
        a = k / n * math.tau
        w = 1.0 + wobble * math.sin(3 * a + cx * 7.0)
        x, z = rx * w * math.cos(a), rz * w * math.sin(a)
        ct, st = math.cos(tilt), math.sin(tilt)
        pts.append((cx + x * ct - z * st, cz + x * st + z * ct))
    me = _slab(pts, y + 0.008, y - 0.014, 0.006, 1, name)
    return K.Piece(me, pal, outline=False, smooth=False, name=name)


def _paint_ring(piece):
    """Inner bevel light, outer rim dark, reveal lavender (lighter toward the sky)."""
    pal = []
    for f in piece.mesh.polygons:
        c, n = f.center, f.normal
        rx, rz = c.x, c.z - CZ
        rl = math.hypot(rx, rz) or 1.0
        radial = (n.x * rx + n.z * rz) / rl  # +1 = facing away from the centre
        if c.y > -0.8 and radial < -0.8 and rl < R_IN + 0.05:
            pal.append(REVEAL if c.y > -0.42 else REVEAL_D)
        elif radial < -0.3:
            pal.append(RING_L)
        elif radial > 0.55:
            pal.append(RING_D)
        else:
            pal.append(RING)
    piece.face_pal = pal
    return piece


def _preview_tint(obj, pal):
    """UVs on an untextured part pointing at the swatch of its in-game colour: previews only (the
    part has no material, so nothing is textured in game)."""
    uv = obj.data.uv_layers.new(name="UVMap")
    u, v = K.swatch_uv(pal)
    for loop in uv.data:
        loop.uv = (u, v)
    return obj



def _camera_only(outline):
    """Cycles-only flags (no effect on the GLB or the game): in the preview renders the inverted hull
    otherwise blocks all bounce and sky light from the faces it wraps, so every face the sun misses
    (undersides, insets, the inside of recesses) renders black whatever its paint. Roblox doesn't
    ray-trace ambient light, so this is closer to how the game shows the prop."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False

def build():
    p = []
    # ring frame: reveal (back to front), round inner lip, flat-ish front, big round outer edge, and
    # the back on the wall closes the loop (the hull needs a back to ink the silhouette)
    lip_r, out_r = 0.16, 0.28
    prof = [(R_IN, 0.0), (R_IN, -0.4)]
    prof += [(R_IN + lip_r - lip_r * math.cos(t), -DEPTH + lip_r - lip_r * math.sin(t))
             for t in [k / 6 * math.pi / 2 for k in range(7)]]
    prof += [(R_OUT - out_r + out_r * math.sin(t), -DEPTH + out_r - out_r * math.cos(t))
             for t in [k / 7 * math.pi / 2 for k in range(8)]]
    prof += [(R_OUT, -0.3), (R_OUT, 0.0)]
    ring = K.Piece(_lathe(prof, SEG, "ring"), RING, outline=True, smooth=False, name="ring")
    p.append(_paint_ring(ring))

    # night sky disc deep in the reveal (no outline: the reveal hides its rim)
    sky = K.cylinder(SKY, R_IN + 0.03, 0.03, M((0, SKY_Y + 0.015, CZ), rot=(math.pi / 2, 0, 0)), seg=SEG,
                     outline=False, smooth=False, name="sky")
    p.append(sky)

    # stars: the art's cyan dot inside the bite, plus two tiny ones
    for (x, z, r) in ((0.9, 0.76, 0.1), (1.66, 0.12, 0.055), (0.72, -1.5, 0.05)):
        p.append(_blob(x, z, r, r, 0.0, SKY_Y, STAR, "star", n=8, wobble=0.0))

    # craters on the moon's front (part of the textured body, so they stay tan on the glowing moon)
    for (x, z, rx, rz, tilt) in ((-1.08, 1.2, 0.14, 0.19, -0.45), (-0.92, -0.31, 0.18, 0.13, 0.2),
                                 (-0.15, -0.82, 0.23, 0.14, 0.12)):
        p.append(_blob(x, z, rx, rz, tilt, MOON_Y1, CRATER, "crater"))

    # the crescent: MoonGlow (untextured, the game makes it Neon) + its ink outline in the hull
    moon = K.Piece(_moon_mesh(0.0, "moon"), 0, outline=False, smooth=True, name="moon")
    glow = K.plain_object([moon], "MoonGlow")
    bpy.data.meshes.remove(moon.mesh)
    _preview_tint(glow, MOON)
    glow.visible_shadow = False  # the game turns the moon's shadow off too (Map.luau GLOW_PARTS)
    # the hull inflates every piece by OUTLINE: its moon is an eroded copy, so the line comes out
    # MOON_LINE wide (finer, as the art inks it)
    ink = K.Piece(_moon_mesh(OUTLINE - MOON_LINE, "moon_ink"), 0, outline=True, smooth=True, name="moon_ink")

    body, outline = K.finish(p, NAME, outline_width=OUTLINE, outline_only=[ink])
    _camera_only(outline)
    return [body, outline, glow] + K.markers(NAME)
