"""
props/picture.py - the Picture prop (ReplicatedStorage.MapMeshes.Picture): the framed landscape on
the bedroom wall. See props/__init__.py for the conventions every prop follows.

Art (docs/concept/bedroom_keyframe.png, top-left corner behind the Roblox menu): a chunky orange
wooden frame - flat front face, softly rounded outer edge with an ink line, a narrow dark inner bevel
stepping down to the canvas - round a flat, painterly landscape: blue sky, one big white fluffy
cloud, one continuous mid-green hill with a single crest line (a hairline of darker green along the
canvas bottom) and light yellow-green grass tufts poking up from the crest - chunky, slightly tilted
flat blocks, each in front of a wider, flat-topped step of darker green that rises out of the crest
behind it. The painting itself has no ink lines; only a hairline of ink runs round the canvas edge.

Wall-mounted: flat back on the wall at y = 0, the front faces -Y; origin = bottom centre of the
back. Landscape 5.2 x 4.04 (Map.luau fit box 54 x 42 x 6 has the same 1.29 : 1).
"""
import math
import bmesh
import bpy
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "Picture"
EXPORT_DIR = "map"

# frame: sampled from the lamp-lit frame in the keyframe
FRAME = hexcol("picture_frame", "#CC672F")          # front face
FRAME_L = hexcol("picture_frame_light", "#E58C4A")  # top-facing edges and bevels
FRAME_S = hexcol("picture_frame_side", "#9A4C2C")   # outer sides
FRAME_D = hexcol("picture_frame_dark", "#7A3122")   # inner bevel in shadow, undersides
# painting (the art's colours are tinted by the warm lamp light; these are the clean versions)
SKY = hexcol("picture_sky", "#6383B0")             # dusty mid-blue (art #56677C), lifted like the frame
CLOUD = hexcol("picture_cloud", "#F7F4F0")
HILL = hexcol("picture_hill", "#4D8226")           # the one hill (art #507C29)
HILL_D = hexcol("picture_hill_dark", "#3D7130")    # shadow strip along the canvas bottom (art #406A30)
HILL_STEP = hexcol("picture_hill_step", "#477528") # the darker step behind a tuft (art #4A7529)
TUFT = hexcol("picture_tuft", "#86A72F")           # flat light yellow-green tuft (art #829F30)

W, H = 5.2, 4.04      # outer size
D = 0.44              # wall to frame front
BAND = 0.5            # frame width (outer edge to the canvas)
CANVAS_Y = -0.15      # canvas front (recessed behind the frame front)
OUTLINE = 0.07
INK = 0.035           # painted ink line round the canvas edge

CX0, CX1 = -W / 2 + BAND, W / 2 - BAND   # canvas opening
CZ0, CZ1 = BAND, H - BAND
# painted layers, back to front, >= 0.012 apart (the canvas front is CANVAS_Y, the frame's inner step
# wall reaches to y = -0.28)
CLOUD_Y = CANVAS_Y - 0.015   # cloud
STEP_Y = CANVAS_Y - 0.015    # tuft steps (behind the hill; they never overlap the cloud)
HILL_Y = CANVAS_Y - 0.04     # the hill
SHADOW_Y = CANVAS_Y - 0.055  # shadow strip along the bottom
TUFT_Y = CANVAS_Y - 0.07     # tufts (in front of the hill)
INK_Y = CANVAS_Y - 0.11      # ink round the canvas edge


def _frame():
    """The four rails as one swept profile with mitred corners. Profile points (d, y): d = inset
    from the outer edge, y = depth (0 = wall)."""
    ro = 0.13  # rounded outer front edge
    prof = [(BAND, 0.0), (BAND, -0.28), (BAND - 0.11, -D)]
    prof += [(ro - ro * math.sin(t), -D + ro - ro * math.cos(t)) for t in [k / 4 * math.pi / 2 for k in range(5)]]
    prof += [(0.0, 0.0)]
    bm = bmesh.new()
    loops = []
    for d, y in prof:
        x, z0, z1 = W / 2 - d, d, H - d
        loops.append([bm.verts.new(c) for c in ((-x, y, z0), (x, y, z0), (x, y, z1), (-x, y, z1))])
    # closed profile: the back face lies on the wall (the hull needs it to ink the silhouette)
    for a, b in zip(loops, loops[1:] + loops[:1]):
        for i in range(4):
            j = (i + 1) % 4
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.normal_update()
    front = min(bm.faces, key=lambda f: f.calc_center_median().y)
    if front.normal.y > 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    me = bpy.data.meshes.new("frame")
    bm.to_mesh(me)
    bm.free()
    pal = []
    for f in me.polygons:
        n, c = f.normal, f.center
        inner = c.x > CX0 - 0.2 and c.x < CX1 + 0.2 and c.z > CZ0 - 0.2 and c.z < CZ1 + 0.2
        if n.y < -0.9:
            pal.append(FRAME)
        elif inner and n.y < -0.2:      # the bevel stepping down to the canvas: lit along the bottom,
            # dark brown down the sides; the top one faces down into shadow, so paint it lighter
            pal.append(FRAME_L if n.z > 0.3 else FRAME_S if n.z < -0.3 else FRAME_D)
        elif inner:                     # the short wall at the canvas edge: dark wood (the INK strip
            pal.append(FRAME_D)         # in front of the canvas is the only black line there)
        elif n.z > 0.6:
            pal.append(FRAME_L)
        elif n.z < -0.6:
            pal.append(FRAME_D)
        elif n.y < -0.3:
            pal.append(FRAME)
        else:
            pal.append(FRAME_S)
    return K.Piece(me, pal, outline=True, smooth=False, name="frame")


def _flat(pts, y_front, pal, name):
    """A flat painted shape: the 2D outline (x, z) extruded from inside the canvas to y_front."""
    bm = bmesh.new()
    back = [bm.verts.new((x, CANVAS_Y + 0.02, z)) for x, z in pts]
    front = [bm.verts.new((x, y_front, z)) for x, z in pts]
    bm.faces.new(front)
    bm.faces.new(list(reversed(back)))
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((back[i], back[j], front[j], front[i]))
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return K.Piece(me, pal, outline=False, smooth=False, name=name)


def _band(top, y_front, pal, name, steps=40, bottom=None):
    """The area under the curve z = top(x) across the canvas (down to the canvas bottom)."""
    xs = [CX0 - 0.02 + (CX1 - CX0 + 0.04) * k / steps for k in range(steps + 1)]
    zb = CZ0 - 0.02 if bottom is None else bottom
    pts = [(xs[0], zb), (xs[-1], zb)] + [(x, top(x)) for x in reversed(xs)]
    return _flat(pts, y_front, pal, name)


def _bump(x, c, w):
    return math.exp(-((x - c) / w) ** 2)


def _cloud(y_front):
    """One big puffy cloud: the upper envelope of round lobes, and a lumpy underside of three shallow
    hanging bumps (the art's cloud is a big ball about half the canvas tall, lumpy all round)."""
    ox, oz = -0.15, 2.26  # centre of the cloud's underside
    discs = [(ox + dx, oz + dz, r) for dx, dz, r in ((0.0, 0.57, 0.57), (-0.55, 0.46, 0.46), (0.58, 0.44, 0.47),
                                                     (-0.3, 0.8, 0.32), (0.32, 0.78, 0.33),
                                                     (-0.92, 0.26, 0.3), (0.94, 0.24, 0.3))]
    bumps = [(ox + dx, hw, dep) for dx, hw, dep in ((-0.66, 0.36, 0.1), (0.04, 0.42, 0.13), (0.7, 0.34, 0.09))]
    x0 = min(cx - r for cx, cz, r in discs)
    x1 = max(cx + r for cx, cz, r in discs)

    def env(x, sign):
        vals = [cz + sign * math.sqrt(r * r - (x - cx) ** 2) for cx, cz, r in discs if abs(x - cx) <= r]
        return (max(vals) if sign > 0 else min(vals)) if vals else oz

    def under(x):  # the lumpy underside: cusps at oz, rounded bumps hanging below it
        z = oz
        for c, hw, dep in bumps:
            u = (x - c) / hw
            if abs(u) < 1:
                z = min(z, oz - dep * math.sqrt(1 - u * u))
        return max(z, env(x, -1))

    n = 64
    xs = [x0 + (x1 - x0) * (1 - math.cos(math.pi * k / n)) / 2 for k in range(n + 1)]
    pts = [(x, env(x, 1)) for x in xs] + [(x, under(x)) for x in reversed(xs[1:-1])]
    clean = [pts[0]]
    for q in pts[1:]:
        if abs(q[0] - clean[-1][0]) + abs(q[1] - clean[-1][1]) > 1e-3:
            clean.append(q)
    # counter-clockwise for _flat (the top runs left to right, so reverse)
    return _flat(list(reversed(clean)), y_front, CLOUD, "cloud")


def _tuft(x, z, w, h, tilt, y_front, crest, step=(0.4, 0.6), slant=0.03):
    """A grass tuft: one flat light block with a slightly slanted top, standing in the grass with its
    base at z, plus the wider step of darker hill green that rises out of the crest behind it (the
    art draws one behind the big tuft: about twice its width, its flat top close to the tuft's top,
    following the crest). The step sits behind the hill, so only the part above the crest shows.
    step = how far the step reaches past the tuft's left / right edge, in tuft widths."""
    ct, st = math.cos(tilt), math.sin(tilt)
    za, zb = h + slant, h - slant
    q = [(-w / 2, 0.0), (w / 2, 0.0), (w / 2, zb), (-w / 2, za)]
    tuft = [(x + px * ct - pz * st, z + px * st + pz * ct) for px, pz in q]
    xl, xr = x - w / 2 - step[0] * w, x + w / 2 + step[1] * w
    rise = 0.94 * h - (crest(x) - z)  # the step's top runs a little under the tuft's top
    sb = z - 0.1
    sq = [(xl, sb), (xr, sb), (xr, crest(xr) + rise), (xl, crest(xl) + rise)]
    return [_flat(sq, STEP_Y, HILL_STEP, "tuft_step"), _flat(tuft, y_front, TUFT, "tuft")]


def _camera_only(outline):
    """Cycles-only flags (no effect on the GLB or the game): in the preview renders the inverted hull
    otherwise blocks all bounce and sky light from the faces it wraps, so every face the sun misses
    (undersides, insets, the inside of recesses) renders black whatever its paint. Roblox doesn't
    ray-trace ambient light, so this is closer to how the game shows the prop."""
    outline.visible_diffuse = False
    outline.visible_glossy = False
    outline.visible_transmission = False

def build():
    p = [_frame()]
    # canvas = the sky (no outline: the frame hides its edges)
    p.append(K.rounded_box(SKY, (CX1 - CX0 + 0.1, 0.12, CZ1 - CZ0 + 0.1),
                           M((0, CANVAS_Y + 0.06, (CZ0 + CZ1) / 2)), bevel=0.01, segments=1, outline=False, name="canvas"))

    def hill(x):
        """The single crest line: nearly level across the canvas (the art's visible right part), a
        soft hump left of the cloud and a slow rise into the left corner."""
        return CZ0 + 1.2 + 0.1 * _bump(x, -0.8, 0.75) - 0.07 * _bump(x, 2.1, 0.7) + 0.16 * _bump(x, -2.2, 0.7)

    p.append(_cloud(CLOUD_Y))
    p.append(_band(hill, HILL_Y, HILL, "hill"))
    # a hairline of darker green along the bottom, under the frame's lip
    p.append(_band(lambda x: CZ0 + 0.07, SHADOW_Y, HILL_D, "hill_shadow", steps=1))
    # ink line round the canvas edge (the art draws one where the canvas meets the frame)
    o, i = 0.05, INK
    for x0, z0, x1, z1 in ((CX0 - o, CZ0 - o, CX1 + o, CZ0 + i), (CX0 - o, CZ1 - i, CX1 + o, CZ1 + o),
                           (CX0 - o, CZ0 - o, CX0 + i, CZ1 + o), (CX1 - i, CZ0 - o, CX1 + o, CZ1 + o)):
        p.append(_flat([(x0, z0), (x1, z0), (x1, z1), (x0, z1)], INK_Y, K.OUTLINE, "ink"))
    # grass tufts poking up from the crest, about a third of each above it: the art shows the big one
    # right of centre (leaning right, its step reaching further right) and one at the far left (leaning
    # left; its step reaches left, nothing shows on its right); the right third has none
    for x, w, h, tilt, step in ((-1.05, 0.38, 0.56, 0.12, (0.75, -0.2)), (0.72, 0.42, 0.58, -0.13, (0.4, 0.65))):
        z = hill(x) - h * 0.66
        p += _tuft(x, z, w, h, tilt, TUFT_Y, hill, step)

    body, outline = K.finish(p, NAME, outline_width=OUTLINE)
    _camera_only(outline)
    return [body, outline] + K.markers(NAME)
