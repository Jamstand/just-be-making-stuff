"""
props/ceilingfan.py - the CeilingFan prop (ReplicatedStorage.MapMeshes.CeilingFan): a chunky cartoon
ceiling fan hanging from the middle of the bedroom ceiling. See props/__init__.py for the conventions
every prop follows.

Players are sock-sized, so they see it mostly from BELOW (and from the side): a cream canopy cup with
a brass flange against the ceiling, a brass downrod with a ball joint and a coupler collar, a fat
cream motor housing with a raised brass band, a brass rotor ring, five wide two-tone wooden paddle
blades (lit tops, a warm wood underside with a lighter inset panel) on swooping brass blade irons,
and a light kit under the motor - a cream switch housing, a brass fitter, a frosted schoolhouse
globe - plus a brass pull chain with a little bead.

Proportions: blade span 10 units = 5 x the motor housing's width (2.0); total height 5 = half the
span (Map fit box 220 x 110 x 220). Origin (floor centre) = the bottom of the globe on the axis; the
canopy top (z = 5) is the highest point - the game hangs it so the canopy touches the ceiling.

Exported objects:
- `CeilingFan` (textured static body) and `CeilingFan_Outline` (its inverted hull; the globe's ink
  line in it is a warm amber, as round the bedside lamp's globe).
- `FanBlades` = the five blades, their blade irons and the rotor ring as ONE textured object WITH
  its own ink hull merged in (the inside-out hull faces, on the ink swatch, follow the blade faces in
  the mesh), so the spinning part keeps its ink lines. The client spins it about the vertical axis
  through `CeilingFan_Pin` (SockFX). CastShadow must stay off on it (Map.luau SPIN_PARTS does that):
  the merged hull would otherwise shadow the blades in Roblox's shadow map.
- `FanLight` = the frosted globe, untextured: the game makes it glow Neon warm white.
- Markers `CeilingFan_Base`, `CeilingFan_Unit` and `CeilingFan_Pin` = (0, 0, Z_HUB): the blades'
  rotation centre on the vertical axis (the height of the blade plane at the root).
"""
import math
import bmesh
import bpy
from mathutils import Vector
import sockkit as K
from sockkit import M, hexcol
from props.common import *  # noqa: F401,F403 - shared colours (read-only)

NAME = "CeilingFan"
EXPORT_DIR = "map"

# ---------------------------------------------------------------- palette
WOOD = hexcol("ceilingfan_wood", "#C8693A")          # blade underside (what players mostly see)
WOOD_L = hexcol("ceilingfan_wood_light", "#EC9A58")  # blade tops (lit)
WOOD_D = hexcol("ceilingfan_wood_dark", "#8E4529")   # blade edges
WOOD_IN = hexcol("ceilingfan_wood_inset", "#DE8549")  # lighter inset panel on the underside
BRASS = hexcol("ceilingfan_brass", "#D7A443")
BRASS_L = hexcol("ceilingfan_brass_light", "#F5D274")
BRASS_D = hexcol("ceilingfan_brass_dark", "#A06E2A")
CREAM = hexcol("ceilingfan_cream", "#F0E1C4")
CREAM_L = hexcol("ceilingfan_cream_light", "#FBF4E4")
CREAM_D = hexcol("ceilingfan_cream_dark", "#D6BE9E")  # undersides
GLOBE_C = hexcol("ceilingfan_globe", "#FFF1D2")      # preview tint only (the game makes FanLight Neon)
GLOBE_INK = hexcol("ceilingfan_globe_ink", "#C98F2E")  # warm amber ink round the glowing globe

# ---------------------------------------------------------------- layout (units; Z up, origin = globe bottom)
SEG = 32            # segments round the lathed parts
R_TIP = 5.0         # blade tip radius -> span 10
R_ROOT = 1.42       # where the wooden blade starts
Z_TOP = 5.0         # canopy top (touches the ceiling)
Z_HUB = 1.70        # blade plane at the root = the spin centre height (CeilingFan_Pin)
BLADE_T = 0.17      # blade thickness (chunky toy paddles)
PITCH = math.radians(9)
N_BLADES = 5
OUT = 0.085         # ink width (~0.85% of the span; the parts are slender, so a touch under 1%)


# ---------------------------------------------------------------- helpers
def _paint(piece, base, light=None, dark=None, up=0.55, down=-0.55):
    """Flat toon tones by face normal: top-facing `light`, undersides `dark`, the rest `base`."""
    pals = []
    for f in piece.mesh.polygons:
        nz = f.normal.z
        pals.append(light if (light is not None and nz > up) else dark if (dark is not None and nz < down) else base)
    piece.face_pal = pals
    return piece


def _flat_caps(piece, cut=0.97):
    """Flat shading on the near-horizontal faces (lathe caps) so smoothing doesn't smear them."""
    piece.flat_faces = [i for i, f in enumerate(piece.mesh.polygons) if abs(f.normal.z) > cut]
    return piece


def _lathe(profile, pal, seg=SEG, name="lathe", outline=True, closed=False):
    """Revolves (r, z) points about the Z axis. Either the profile starts and ends on the axis (r = 0)
    or `closed` joins its last point back to the first (a ring); the result is a closed shell whose
    normals face out."""
    bm = bmesh.new()
    rings = []
    for r, z in profile:
        if r < 1e-6:
            v = bm.verts.new((0.0, 0.0, z))
            rings.append([v] * seg)
        else:
            rings.append([bm.verts.new((r * math.cos(j / seg * math.tau), r * math.sin(j / seg * math.tau), z))
                          for j in range(seg)])
    n = len(profile)
    for i in range(n if closed else n - 1):
        a, b = rings[i], rings[(i + 1) % n]
        for j in range(seg):
            j2 = (j + 1) % seg
            q = [a[j], a[j2], b[j2], b[j]]
            q = [v for k, v in enumerate(q) if v not in q[:k]]
            if len(q) >= 3:
                bm.faces.new(q)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return K.Piece(K._bm_to_mesh(bm, name), pal, outline, True, name)


def _arc(cr, cz, rad, a0, a1, n):
    """Points on a quarter / half circle in the (r, z) profile plane (angles in degrees)."""
    return [(cr + rad * math.cos(math.radians(a0 + (a1 - a0) * k / n)), cz + rad * math.sin(math.radians(a0 + (a1 - a0) * k / n)))
            for k in range(n + 1)]


def _catmull(pts, steps):
    """A smooth Catmull-Rom curve through `pts` (Vectors), `steps` samples per span."""
    out = []
    p = [pts[0] + (pts[0] - pts[1])] + list(pts) + [pts[-1] + (pts[-1] - pts[-2])]
    for i in range(1, len(p) - 2):
        p0, p1, p2, p3 = p[i - 1], p[i], p[i + 1], p[i + 2]
        for s in range(steps):
            t = s / steps
            t2, t3 = t * t, t * t * t
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    out.append(p[-2])
    return out


def _sweep(path, width, thick, roll, pal, name, steps=4, corner=0.35):
    """A flat bar along `path` (points in the local X-Z plane): a rounded-rectangle section `width`
    across (local Y) and `thick` tall, both callables of t in 0..1 along the path, and `roll(t)` (radians)
    turning the section about the path. Closed with flat end caps."""
    pts = _catmull([Vector(p) for p in path], steps)
    n = len(pts)
    # rounded-rectangle section (8 points), corners cut by `corner` of the half thickness
    def section(w, h):
        hw, hh = w / 2, h / 2
        c = hh * corner * 2
        return [(hw, hh - c), (hw - c, hh), (-hw + c, hh), (-hw, hh - c), (-hw, -hh + c), (-hw + c, -hh), (hw - c, -hh), (hw, -hh + c)]
    bm = bmesh.new()
    rings = []
    for i, p in enumerate(pts):
        t = i / (n - 1)
        tan = (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized()
        s0 = Vector((0, 1, 0))
        u0 = tan.cross(s0).normalized()
        rr = roll(t)
        s = s0 * math.cos(rr) + u0 * math.sin(rr)
        u = u0 * math.cos(rr) - s0 * math.sin(rr)
        rings.append([bm.verts.new(p + s * a + u * b) for a, b in section(width(t), thick(t))])
    m = len(rings[0])
    for a, b in zip(rings, rings[1:]):
        for j in range(m):
            j2 = (j + 1) % m
            bm.faces.new((a[j], a[j2], b[j2], b[j]))
    bm.faces.new(rings[0])
    bm.faces.new(list(reversed(rings[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return K.Piece(K._bm_to_mesh(bm, name), pal, True, True, name)


def _preview_tint(obj, pal):
    """UVs on an untextured part pointing at the swatch of its in-game colour: previews only (the part
    has no material, so nothing is textured in game)."""
    uv = obj.data.uv_layers.new(name="UVMap")
    u, v = K.swatch_uv(pal)
    for loop in uv.data:
        loop.uv = (u, v)
    return obj


def _camera_only(obj):
    """Cycles-only flags (no effect on the GLB / game): keep the hull from blocking bounce and sky light
    in the preview renders (Roblox doesn't ray-trace ambient light)."""
    obj.visible_diffuse = False
    obj.visible_glossy = False
    obj.visible_transmission = False


# ---------------------------------------------------------------- the static body
def _canopy(p):
    """Round cream cup against the ceiling with a brass flange, the downrod's ball joint under it."""
    prof = [(0.0, 4.30), (0.26, 4.30)] + _arc(0.26, 4.42, 0.12, -90, 0, 3)[1:]
    prof += [(0.46, 4.56), (0.58, 4.70), (0.72, 4.82), (0.84, 4.88), (0.88, 4.885)]
    cup = _lathe(prof + [(0.0, 4.885)], CREAM, name="canopy")
    p.append(_flat_caps(_paint(cup, CREAM, CREAM_L, CREAM_D, up=0.75, down=-0.35)))
    fl = [(0.0, 4.86), (0.86, 4.86)] + _arc(0.86, 4.92, 0.06, -90, 0, 2)[1:] + [(0.92, Z_TOP - 0.02), (0.90, Z_TOP), (0.0, Z_TOP)]
    p.append(_flat_caps(_paint(_lathe(fl, BRASS, name="canopy_flange"), BRASS, BRASS_L, BRASS_D)))
    # ball joint at the top of the downrod, half sunk into the cup
    ball = K.sphere(BRASS, 0.2, M((0, 0, 4.30), scale=(1, 1, 0.9)), seg=16, rings=8, name="ball")
    p.append(_paint(ball, BRASS, BRASS_L, BRASS_D, up=0.6, down=-0.6))


def _downrod(p):
    p.append(_paint(K.cylinder(BRASS, 0.115, 1.5, M((0, 0, 3.55)), seg=14, name="downrod"), BRASS, BRASS_L, BRASS_D))
    # coupler collar where the rod enters the motor
    col = [(0.0, 2.70), (0.25, 2.70), (0.27, 2.74), (0.27, 2.94), (0.24, 2.98), (0.0, 2.98)]
    p.append(_flat_caps(_paint(_lathe(col, BRASS, seg=20, name="collar"), BRASS, BRASS_L, BRASS_D)))
    pin = K.sphere(BRASS_D, 0.05, M((0.27, 0, 2.86)), seg=8, rings=4, outline=False, name="collar_pin")
    p.append(pin)


def _motor(p):
    """Fat cream motor housing: a rounded drum with a soft dome on top and a raised brass band."""
    prof = [(0.0, 1.84), (0.94, 1.84)] + _arc(0.94, 1.92, 0.08, -90, 0, 2)[1:]
    prof += [(1.02, 2.30)] + _arc(0.72, 2.30, 0.30, 0, 90, 4)[1:] + [(0.3, 2.66), (0.0, 2.68)]
    body = _lathe(prof, CREAM, name="motor")
    p.append(_flat_caps(_paint(body, CREAM, CREAM_L, CREAM_D, up=0.6, down=-0.5)))
    band = K.torus(BRASS, 1.025, 0.06, M((0, 0, 2.06)), seg=SEG, mseg=8, name="motor_band")
    p.append(_paint(band, BRASS, BRASS_L, BRASS_D, up=0.5, down=-0.5))
    # a row of little brass rivets round the dome (cheap detail that reads from below and the side)
    for k in range(8):
        a = (k + 0.5) / 8 * math.tau
        r, z = 0.93, 2.42
        p.append(K.sphere(BRASS_L, 0.045, M((r * math.cos(a), r * math.sin(a), z)), seg=6, rings=4, outline=False, name="rivet"))


def _light_kit(p):
    """Cream switch housing under the rotor and a brass fitter cup holding the globe."""
    sh = [(0.0, 1.20), (0.56, 1.20)] + _arc(0.56, 1.42, 0.22, -90, 0, 3)[1:] + [(0.78, 1.60), (0.0, 1.60)]
    p.append(_flat_caps(_paint(_lathe(sh, CREAM, name="switch_housing"), CREAM, CREAM_L, CREAM_D, up=0.6, down=-0.45)))
    ring = K.torus(BRASS, 0.62, 0.045, M((0, 0, 1.235)), seg=SEG, mseg=6, name="kit_ring")
    p.append(_paint(ring, BRASS, BRASS_L, BRASS_D))
    fit = [(0.0, 0.94), (0.36, 0.94)] + _arc(0.40, 0.98, 0.04, -90, 0, 2)[1:]
    fit += [(0.47, 1.06), (0.50, 1.20), (0.0, 1.20)]
    p.append(_flat_caps(_paint(_lathe(fit, BRASS, seg=24, name="fitter"), BRASS, BRASS_L, BRASS_D, up=0.6, down=-0.5)))


def _pull_chain(p, ink):
    """A thin brass chain from the switch housing's rim, ending in a little bead (its ink comes from an
    eroded copy in the hull, so the bead's line is thin, not a black ball)."""
    a = math.radians(-50)
    x, y = 0.74 * math.cos(a), 0.74 * math.sin(a)  # off the housing's rim, clear of the globe
    z0, z1 = 1.30, 0.40
    p.append(K.cylinder(BRASS_D, 0.028, z0 - z1, M((x, y, (z0 + z1) / 2)), seg=6, outline=False, name="chain"))
    bead_m = M((x, y, z1 - 0.08), scale=(1, 1, 1.25))
    p.append(_paint(K.sphere(BRASS, 0.1, bead_m, seg=10, rings=6, outline=False, name="bead"), BRASS, BRASS_L, BRASS_D, up=0.4, down=-0.4))
    ink.append(K.sphere(0, 0.1 - OUT + 0.035, bead_m, seg=10, rings=6, name="bead_ink"))


def _globe_profile():
    return [(0.0, 0.0), (0.18, 0.012), (0.34, 0.06), (0.47, 0.15), (0.56, 0.27), (0.61, 0.42), (0.60, 0.57),
            (0.54, 0.72), (0.45, 0.84), (0.37, 0.93), (0.345, 1.00), (0.345, 1.04), (0.0, 1.04)]


# ---------------------------------------------------------------- the spinning part
def _paddle_outline():
    """2D outline (u along the blade from its root, v across) of one paddle, counter-clockwise: a slightly
    widening blade with rounded root corners and a round tip."""
    L = R_TIP - R_ROOT
    w0, w1, a, b = 0.96, 1.34, 0.62, 0.67
    rc = 0.14

    def half(u):
        return (w0 + (w1 - w0) * min(1.0, u / (L - a))) / 2
    us = [rc + (L - a - rc) * k / 2 for k in range(3)]  # the sides are straight
    pts = [(u, -half(u)) for u in us]
    pts += [(L - a + a * math.cos(t), b * math.sin(t)) for t in [math.radians(-90 + 180 * k / 10) for k in range(1, 10)]]
    pts += [(u, half(u)) for u in reversed(us)]
    # rounded root corners and the straight root edge
    h0 = half(0)
    pts += [(rc - rc * math.sin(t), h0 - rc + rc * math.cos(t)) for t in [math.radians(30), math.radians(60)]]
    pts += [(0.0, h0 - rc), (0.0, -h0 + rc)]
    pts += [(rc - rc * math.cos(t), -h0 + rc - rc * math.sin(t)) for t in [math.radians(30), math.radians(60)]]
    return pts


def _slab(pts, z0, z1, bevel, segs, name):
    """Extrudes a convex 2D outline (x, y) from z0 to z1 and rounds its rim (angle-limited bevel)."""
    bm = bmesh.new()
    lo = [bm.verts.new((x, y, z0)) for x, y in pts]
    hi = [bm.verts.new((x, y, z1)) for x, y in pts]
    n = len(pts)
    bm.faces.new(hi)
    bm.faces.new(list(reversed(lo)))
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = K._bm_to_mesh(bm, name)
    obj = bpy.data.objects.new(name, me)
    K.link(obj)
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = bevel
    mod.segments = segs
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(50)
    mod.harden_normals = False
    return K.bake_object(obj)


def _blade(angle):
    """One wooden paddle: lit top, warm underside with a lighter inset panel, darker rounded edges."""
    pts = _paddle_outline()
    me = _slab(pts, -BLADE_T / 2, BLADE_T / 2, 0.055, 2, "blade")
    xf = M((0, 0, Z_HUB), rot=(0, 0, angle)) @ M((R_ROOT, 0, 0), rot=(PITCH, 0, 0))
    me.transform(xf)
    me.update()
    blade = K.Piece(me, WOOD, True, True, "blade")
    for i, f in enumerate(me.polygons):
        nz = f.normal.z
        blade.face_pal[i] = WOOD_L if nz > 0.6 else WOOD if nz < -0.6 else WOOD_D
    blade.flat_faces = [i for i, f in enumerate(me.polygons) if abs(f.normal.z) > 0.97]
    # lighter inset panel on the underside: the outline shrunk toward the blade's middle (~0.13-0.18 in
    # from the sides, ~0.3 from the ends), a hair under the wood
    L = R_TIP - R_ROOT
    panel = [(0.30 + x * (L - 0.62) / L, y * (1 - 0.32 / 1.2)) for x, y in pts]
    bm = bmesh.new()
    zp = -BLADE_T / 2 - 0.012
    bm.faces.new([bm.verts.new((u, v, zp)) for u, v in reversed(panel)])  # faces down
    pm = K._bm_to_mesh(bm, "blade_panel")
    pm.transform(xf)
    pm.update()
    return blade, K.Piece(pm, WOOD_IN, False, False, "blade_panel")


def _iron(angle):
    """A swooping brass blade iron from under the rotor ring out under the blade's root."""
    path = [(0.70, 0, 1.52), (0.98, 0, 1.475), (1.24, 0, 1.47), (1.46, 0, 1.51), (1.66, 0, 1.565),
            (1.90, 0, 1.585), (2.20, 0, 1.585), (2.48, 0, 1.585)]
    # follow the blade's pitch where the iron runs under it (the blade's underside at the iron's centre)
    iron = _sweep(path, lambda t: 0.28 + 0.14 * min(1.0, t * 1.6), lambda t: 0.09,
                  lambda t: PITCH * min(1.0, max(0.0, (t - 0.45) / 0.25)), BRASS, "iron", steps=2)
    iron.mesh.transform(M((0, 0, 0), rot=(0, 0, angle)))
    iron.mesh.update()
    _paint(iron, BRASS, BRASS_L, BRASS_D, up=0.6, down=-0.6)
    # two brass bolt heads on the underside of the iron's plate
    bolts = []
    for r in (1.95, 2.32):
        z = 1.585 - 0.045 - 0.008
        m = M((0, 0, 0), rot=(0, 0, angle)) @ M((r, 0, z), scale=(1, 1, 0.6))
        bolts.append(_paint(K.sphere(BRASS_L, 0.055, m, seg=6, rings=3, outline=False, name="bolt"), BRASS_L, BRASS_L, BRASS))
    return iron, bolts


def _rotor():
    prof = [(0.62, 1.56), (0.98, 1.56)] + _arc(0.98, 1.64, 0.08, -90, 0, 1)[1:] + _arc(0.98, 1.76, 0.08, 0, 90, 1)[1:] + [(0.62, 1.84)]
    return _flat_caps(_paint(_lathe(prof, BRASS, seg=24, closed=True, name="rotor"), BRASS, BRASS_L, BRASS_D, up=0.6, down=-0.6))


def _join(objs, name):
    """Joins objects into objs[0] (renamed `name`)."""
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    with bpy.context.temp_override(active_object=objs[0], object=objs[0], selected_objects=objs,
                                   selected_editable_objects=objs):
        bpy.ops.object.join()
    obj = objs[0]
    obj.name = name
    obj.data.name = name
    obj.select_set(False)
    return obj


def build():
    p, ink = [], []
    _canopy(p)
    _downrod(p)
    _motor(p)
    _light_kit(p)
    _pull_chain(p, ink)
    # the globe: its own untextured object (FanLight) + its ink in the body hull (recoloured amber below)
    globe_ink = _lathe(_globe_profile(), 0, seg=SEG, name="globe_ink")
    n_globe = len(globe_ink.mesh.polygons)
    body, outline = K.finish(p, NAME, outline_width=OUT, outline_only=ink + [globe_ink])
    uv = outline.data.uv_layers["UVMap"].data
    gu = K.swatch_uv(GLOBE_INK)
    nf = len(outline.data.polygons)
    for f in outline.data.polygons:
        if f.index >= nf - n_globe:
            for li in f.loop_indices:
                uv[li].uv = gu
    _camera_only(outline)

    # the spinning part: blades + irons + rotor ring, with its own ink hull merged in
    bp = [_rotor()]
    for k in range(N_BLADES):
        a = math.radians(90 + k * 360 / N_BLADES)
        blade, panel = _blade(a)
        iron, bolts = _iron(a)
        bp += [blade, panel, iron] + bolts
    bbody, bline = K.finish(bp, "FanBlades", outline_width=OUT)
    blades = _join([bbody, bline], "FanBlades")
    # like an outline object: no shadow from the merged hull onto the blades it wraps (the game turns
    # CastShadow off on FanBlades for the same reason)
    blades.visible_shadow = False
    _camera_only(blades)

    globe = _lathe(_globe_profile(), 0, seg=SEG, outline=False, name="globe")
    light = K.plain_object([globe], "FanLight")
    for f in light.data.polygons:
        f.use_smooth = True
    _preview_tint(light, GLOBE_C)
    light.visible_shadow = False
    return [body, outline, blades, light] + K.markers(NAME, pin=(0.0, 0.0, Z_HUB))
