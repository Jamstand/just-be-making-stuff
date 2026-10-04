"""
Weapon meshes: the 6 base weapons (My Avatar players and stage pickups) and the
legends' 12 signature skins.

Weapon frame (the same as src/shared/WeaponModels.luau): the grip, where the
fist closes, is at the origin; the weapon points along +Y; its broad side (the
flat of a blade, the faces of a hammer head) lies along Z, so it faces the 2D
camera when held, and the camera looks along X. Every coordinate below is in
this frame. MeshBuilder converts it with RIG_TO_BLENDER and export_fbx undoes
that, so the FBX axes equal the weapon frame.

Each weapon exports art/export/weapons/<Id>.fbx holding a "Body" mesh, an
optional "Glow" mesh (the parts the game turns Neon) and the three import
markers. All weapons share one palette texture, Weapons_palette.png.
Building also regenerates src/shared/WeaponMeshes.luau and renders
art/previews/weapons/Weapons.jpg.
"""

import math
import os
from collections import namedtuple

import bpy  # noqa: I001 (bpy must load before bmesh)
import bmesh
from mathutils import Vector

from sky import common
from sky.common import RIG_TO_BLENDER, MeshBuilder, Palette

EXPORT_DIR = os.path.join(common.EXPORT_DIR, "weapons")
PREVIEW_PATH = os.path.join(common.PREVIEW_DIR, "weapons", "Weapons.png")
LUAU_PATH = os.path.join(common.SHARED_SRC, "WeaponMeshes.luau")
MAX_TRIANGLES = 3000

# One palette for every weapon, so the game uploads a single texture.
COLORS = {
    # steel + wood (base set)
    "steel_hi": "#f1f4f9",
    "steel": "#c2c9d5",
    "steel_mid": "#8f99ab",
    "steel_dark": "#5b6375",
    "wood": "#8e5c34",
    "wood_dark": "#5c391f",
    "wood_light": "#b27d4a",
    "leather": "#6e4024",
    "leather_dark": "#41261a",
    "string": "#efe9d8",
    # Kestrel
    "brass": "#dcaa42",
    "brass_dark": "#9a6f22",
    "grip_black": "#2c2628",
    "pale_wood": "#ecdcae",
    "pale_wood_dark": "#c7a970",
    "teal": "#1f9098",
    "teal_dark": "#13646b",
    # Brann
    "forge_iron": "#4b4e57",
    "forge_iron_dark": "#2d2f36",
    "forge_iron_light": "#737885",
    "ember": "#ff7a1a",
    "ember_plate": "#e8691f",
    "ember_dark": "#a3400f",
    # Yuki
    "silver": "#e1e8f0",
    "silver_dark": "#97a5b8",
    "wrap_white": "#f8f7f3",
    "wrap_shade": "#cfd6e0",
    "ice": "#ccf3ff",
    "ice_deep": "#79cff4",
    "birch": "#f2eee5",
    "birch_mark": "#3b3a41",
    "frost_blue": "#8cc4e8",
    # Moss
    "moss_wood": "#74502c",
    "moss_wood_dark": "#4b311b",
    "vine": "#4f9030",
    "vine_dark": "#2e5f20",
    "leaf": "#8bcc4b",
    "moss": "#62a03b",
    "crystal": "#86ffad",
    "crystal_deep": "#2fc271",
    "bamboo": "#cdc46a",
    "bamboo_dark": "#8b993d",
    "stone": "#929087",
    "stone_dark": "#5f5d57",
    "stone_light": "#b9b7ac",
    "twine": "#caa86a",
    "feather": "#f2ecde",
    "feather_tip": "#b9472d",
    # Vex
    "shadow": "#2a2433",
    "shadow_mid": "#433a53",
    "shadow_light": "#665b7c",
    "violet": "#c47dff",
    "violet_deep": "#8b3ff2",
    # Sol
    "gold": "#f5c445",
    "gold_dark": "#c8891f",
    "gold_light": "#ffe590",
    "sun_glow": "#ffe56e",
    "sun_core": "#fff6c9",
    "black": "#18161a",
}

# Blade cross-sections: (fraction from spine to edge, half thickness along X).
SYM = [(0.0, 0.012), (0.16, 0.032), (0.5, 0.072), (0.84, 0.032), (1.0, 0.012)]
SINGLE = [(0.0, 0.045), (0.28, 0.056), (0.74, 0.03), (1.0, 0.01)]

# Turns a flat outline drawn in (z, y) into the weapon's YZ plane (MeshBuilder.prism).
FLAT = (0, -90, 0)
# Turns a primitive's +Y axis toward +X (the camera), e.g. discs that face it.
FACING = (0, 0, 90)


# Geometry helpers ---------------------------------------------------------


def _new_bm():
    tmp = bmesh.new()
    return tmp, tmp.faces.layers.int.new("color")


def _face(mb, tmp, layer, verts, key):
    face = tmp.faces.new(verts)
    face[layer] = mb.palette.index[key]
    return face


def _emit(mb, tmp, smooth):
    """Adds a bmesh built in weapon space (faces already colored) to `mb`."""
    for face in tmp.faces:
        face.smooth = smooth
    bmesh.ops.transform(tmp, matrix=mb.space.to_4x4(), verts=tmp.verts)
    mesh = bpy.data.meshes.new("tmp")
    tmp.to_mesh(mesh)
    tmp.free()
    mb.bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)
    mb.count += 1


def _ring_faces(mb, tmp, layer, r0, r1, keys):
    if len(r0) == 1 and len(r1) == 1:
        return
    if len(r0) == 1 or len(r1) == 1:
        tip, ring = (r0[0], r1) if len(r0) == 1 else (r1[0], r0)
        for k in range(len(ring)):
            _face(mb, tmp, layer, (tip, ring[k], ring[(k + 1) % len(ring)]), keys[k])
        return
    for k in range(len(r0)):
        j = (k + 1) % len(r0)
        _face(mb, tmp, layer, (r0[k], r0[j], r1[j], r1[k]), keys[k])


def spline(ctrl, samples=5):
    """Catmull-Rom curve through `ctrl` points (any dimension) as Vectors."""
    pts = [Vector(p) for p in ctrl]
    if len(pts) < 3:
        return [pts[0].lerp(pts[-1], i / samples) for i in range(samples + 1)]
    out = []
    for i in range(len(pts) - 1):
        p0 = pts[i - 1] if i > 0 else 2 * pts[0] - pts[1]
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[i + 2] if i + 2 < len(pts) else 2 * pts[-1] - pts[-2]
        for s in range(samples):
            t = s / samples
            out.append(0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (3 * p1 - p0 - 3 * p2 + p3) * t ** 3))
    out.append(pts[-1].copy())
    return out


def arc_params(pts):
    """Normalized arc length (0..1) at each point of a polyline."""
    d = [0.0]
    for a, b in zip(pts, pts[1:]):
        d.append(d[-1] + (b - a).length)
    return [x / d[-1] for x in d]


def table(rows, t):
    """Piecewise-linear lookup in [(t, value, ...), ...]; returns the values."""
    if t <= rows[0][0]:
        return tuple(rows[0][1:])
    for (t0, *a), (t1, *b) in zip(rows, rows[1:]):
        if t <= t1:
            f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
            return tuple(x + (y - x) * f for x, y in zip(a, b))
    return tuple(rows[-1][1:])


def blade_between(mb, spine, edge, profile, colors, thick=None, cap=None):
    """A flat blade between two matched lines of (z, y) points: the spine and
    the edge. `profile` = [(f, half thickness), ...] across from spine (f=0)
    to edge (f=1); it may cover only part of the way (to split a glowing edge
    off into another builder). `colors` has one key per band between profile
    points. A section whose spine and edge meet becomes a point (the tip)."""
    tmp, layer = _new_bm()
    n = len(profile)
    rings = []
    for i, (a, b) in enumerate(zip(spine, edge)):
        a3, b3 = Vector((0.0, a[1], a[0])), Vector((0.0, b[1], b[0]))
        if (a3 - b3).length < 1e-4:
            rings.append([tmp.verts.new(a3)])
            continue
        s = thick[i] if thick else 1.0
        plus = [tmp.verts.new(a3.lerp(b3, f) + Vector((h * s, 0, 0))) for f, h in profile]
        minus = [tmp.verts.new(a3.lerp(b3, f) - Vector((h * s, 0, 0))) for f, h in profile]
        rings.append(plus + minus[::-1])
    m = 2 * n
    keys = []
    for k in range(m):
        if k < n - 1:
            keys.append(colors[k])
        elif k == n - 1:
            keys.append(colors[-1])
        elif k < m - 1:
            keys.append(colors[m - 2 - k])
        else:
            keys.append(colors[0])
    for r0, r1 in zip(rings, rings[1:]):
        _ring_faces(mb, tmp, layer, r0, r1, keys)
    for ring in (rings[0], rings[-1]):
        if len(ring) > 2:
            _face(mb, tmp, layer, ring, cap or colors[0])
    _emit(mb, tmp, smooth=False)


def blade_lines(ctrl, widths, samples=5, thick=None):
    """Spine and edge lines for a (possibly curved) blade. `ctrl` = (z, y)
    points along its middle, base first. `widths` = [(t, back, front), ...]
    over the arc length t: distances from the middle line to the spine (back)
    and to the edge (front, the left side walking base to tip: -Z for a blade
    pointing +Y, -Y for a blade sweeping toward -Z)."""
    pts = spline(ctrl, samples)
    ts = arc_params(pts)
    spine, edge, tk = [], [], []
    for i, p in enumerate(pts):
        tan = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        nrm = Vector((-tan.y, tan.x))
        back, front = table(widths, ts[i])
        spine.append(p - nrm * back)
        edge.append(p + nrm * front)
        tk.append(table(thick, ts[i])[0] if thick else 1.0)
    return spine, edge, tk


def blade(mb, lines, profile, colors, cap=None):
    spine, edge, tk = lines
    blade_between(mb, spine, edge, profile, colors, tk, cap)


def straight_blade(mb, rows, profile, colors, cap=None, z=0.0):
    """rows = [(y, half width, thickness scale), ...] base to tip."""
    spine = [(z + w, y) for y, w, _ in rows]
    edge = [(z - w, y) for y, w, _ in rows]
    blade_between(mb, spine, edge, profile, colors, [s for _, _, s in rows], cap)


def tube(mb, points, radii, color, segments=8, smooth=True, caps=True):
    """Tube through 3D points. `radii` is a list (or a function of arc length
    0..1) of r or (r_side, r_x): r_x is the radius along X (toward the camera),
    r_side the radius in the YZ plane. A zero radius makes a pointed end."""
    pts = [Vector(p) for p in points]
    ts = arc_params(pts)
    if isinstance(radii, (int, float)) or (isinstance(radii, tuple) and len(radii) == 2
                                           and all(isinstance(x, (int, float)) for x in radii)):
        constant = radii
        radii = lambda t: constant  # noqa: E731
    tmp, layer = _new_bm()
    rings = []
    for i, p in enumerate(pts):
        tan = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        r = radii(ts[i]) if callable(radii) else radii[i]
        rn, rx = (r, r) if isinstance(r, (int, float)) else r
        if rn <= 1e-6 and rx <= 1e-6:
            rings.append([tmp.verts.new(p)])
            continue
        bx = Vector((1.0, 0.0, 0.0))
        bx = bx - tan * bx.dot(tan)
        if bx.length < 1e-4:
            bx = Vector((0.0, 0.0, 1.0)) - tan * tan.z
        bx.normalize()
        nn = tan.cross(bx)
        ring = []
        for k in range(segments):
            a = 2 * math.pi * k / segments
            ring.append(tmp.verts.new(p + nn * (rn * math.cos(a)) + bx * (rx * math.sin(a))))
        rings.append(ring)
    keys = [color] * segments
    for r0, r1 in zip(rings, rings[1:]):
        _ring_faces(mb, tmp, layer, r0, r1, keys)
    if caps:
        for ring in (rings[0], rings[-1]):
            if len(ring) > 2:
                _face(mb, tmp, layer, ring, color)
    _emit(mb, tmp, smooth)


def curve_tube(mb, ctrl, radii, color, samples=4, segments=8, smooth=True, caps=True):
    pts = spline(ctrl, samples)
    tube(mb, pts, radii, color, segments, smooth, caps)
    return pts


def crystal(mb, base, tip, r, color, sides=6, shoulder=0.7, foot=0.75):
    """Faceted crystal shard from base to tip."""
    b, t = Vector(base), Vector(tip)
    tube(mb, [b, b.lerp(t, shoulder), t], [r * foot, r, 0.0], color, segments=sides, smooth=False)


def spike(mb, base, tip, r, color, sides=6):
    tube(mb, [base, tip], [r, 0.0], color, segments=sides, smooth=False)


def gem(mb, y, z, half_x, r, color, sides=6, height=0.12):
    """A stud gem through the weapon's thickness: pointed facets on both X faces."""
    tube(mb, [(-half_x - height, y, z), (-half_x, y, z), (half_x, y, z), (half_x + height, y, z)],
         [0.0, r, r, 0.0], color, segments=sides, smooth=False)


def wraps(mb, y0, y1, r, color, step=0.15, tilt=16, thickness=0.022, z=0.0, segments=10):
    """Spiral-looking wrap bands around a shaft along Y."""
    n = max(1, int(round((y1 - y0) / step)))
    for i in range(n):
        y = y0 + (i + 0.5) * (y1 - y0) / n
        mb.torus((0, y, z), r, thickness, color, rotation=(tilt, 0, 0), segments=segments, sides=4)


def wrapped_grip(mb, y0, y1, r, base, band, step=0.15, tilt=16, thickness=0.022):
    mb.cylinder((0, (y0 + y1) / 2, 0), r, y1 - y0, base, segments=10)
    wraps(mb, y0, y1, r, band, step, tilt, thickness)


def stroke(mb, a, b, width, depth, color, x=0.0):
    """A straight bar in the YZ plane from a to b, both (z, y)."""
    dz, dy = b[0] - a[0], b[1] - a[1]
    length = math.hypot(dz, dy)
    angle = math.degrees(math.atan2(dz, dy))
    mb.box((x, (a[1] + b[1]) / 2, (a[0] + b[0]) / 2), (depth, length + width * 0.9, width), color,
           bevel=min(width, depth) * 0.3, segments=1, rotation=(angle, 0, 0))


# Rune glyphs: strokes in a unit square, u across (z), v up (y).
RUNES = {
    "fehu": [((-0.22, -0.5), (-0.22, 0.5)), ((-0.22, 0.18), (0.3, 0.5)), ((-0.22, -0.12), (0.3, 0.2))],
    "algiz": [((0, -0.5), (0, 0.5)), ((0, 0.02), (-0.36, 0.42)), ((0, 0.02), (0.36, 0.42))],
    "dagaz": [((-0.32, -0.45), (-0.32, 0.45)), ((0.32, -0.45), (0.32, 0.45)),
              ((-0.32, 0.45), (0.32, -0.45)), ((-0.32, -0.45), (0.32, 0.45))],
    "tiwaz": [((0, -0.5), (0, 0.5)), ((0, 0.5), (-0.34, 0.12)), ((0, 0.5), (0.34, 0.12))],
    "ingwaz": [((-0.3, 0.5), (0.3, -0.04)), ((0.3, 0.5), (-0.3, -0.04)), ((-0.3, 0.04), (0.3, -0.5)),
               ((0.3, 0.04), (-0.3, -0.5))],
    "sowilo": [((-0.26, 0.5), (0.24, 0.16)), ((0.24, 0.16), (-0.24, -0.16)), ((-0.24, -0.16), (0.26, -0.5))],
}


def rune(mb, name, z, y, size, x, color, width=0.06, depth=0.05):
    """A glyph on the X face at x (use both signs for both faces)."""
    for (u0, v0), (u1, v1) in RUNES[name]:
        stroke(mb, (z - u0 * size, y + v0 * size), (z - u1 * size, y + v1 * size), width, depth, color, x)


def sun_rays(mb, y, z, r_in, r_out, angles, half_width, depth, color, x=0.0):
    """Triangular rays in the YZ plane around (z, y). angles in degrees (0 = -Z,
    the side the preview shows on the right; 90 = +Y)."""
    for ang in angles:
        a = math.radians(ang)
        d = (-math.cos(a), math.sin(a))  # (z, y)
        p = (d[1], -d[0])
        ro = r_out(ang) if callable(r_out) else r_out
        outline = [
            (z + d[0] * r_in + p[0] * half_width, y + d[1] * r_in + p[1] * half_width),
            (z + d[0] * ro, y + d[1] * ro),
            (z + d[0] * r_in - p[0] * half_width, y + d[1] * r_in - p[1] * half_width),
        ]
        mb.prism(outline, depth, color, center=(x, 0, 0), rotation=FLAT, bevel=0.015)


def leaf(mb, base, tip, width, colors=("leaf", "vine"), bend=0.0):
    """A thin two-tone leaf in the YZ plane from base to tip, both (z, y)."""
    bz, by = base
    tz, ty = tip
    mz, my = (bz + tz) / 2, (by + ty) / 2
    # bend the midpoint sideways a little
    nz, ny = -(ty - by), (tz - bz)
    ln = math.hypot(nz, ny) or 1.0
    mid = (mz + nz / ln * bend, my + ny / ln * bend)
    lines = blade_lines([base, mid, tip], [(0, 0.0, 0.0), (0.15, width * 0.7, width * 0.7), (0.45, width, width),
                                           (0.78, width * 0.7, width * 0.7), (1, 0.0, 0.0)], samples=3)
    blade(mb, lines, [(0.0, 0.012), (0.5, 0.03), (1.0, 0.012)], list(colors))


# Shared parts ---------------------------------------------------------------


def bow(b, half_path, limb_r, riser_color, limb_color, string_color="string", bridge=None, samples=4):
    """Bow in the YZ plane: `half_path` = (z, y) points from the grip (z=0)
    out to the +Z tip; the -Z half mirrors it. Limbs bend back toward -Y and the
    string runs on the -Y side. `bridge` = index of the half_path point where a
    recurve's string leaves the limb (None: the string runs tip to tip).
    Returns the sampled +Z half path."""
    half = spline(half_path, samples)
    full = [Vector((-p.x, p.y)) for p in reversed(half)][:-1] + half
    pts = [(0.0, p.y, p.x) for p in full]
    tube(b, pts, lambda t: limb_r(abs(2 * t - 1)), limb_color, segments=8)
    # string: straight between the bridges (or tips), hugging the recurve to the tips
    if bridge is None:
        tip = half[-1]
        rn = limb_r(1.0)[0]
        b.cylinder((0, tip.y - rn * 0.3, 0), 0.022, 2 * tip.x, string_color, rotation=(90, 0, 0), segments=6)
    else:
        i0 = bridge * samples
        seg = half[i0:]
        outer = []
        for i, p in enumerate(seg):
            tan = (seg[min(i + 1, len(seg) - 1)] - seg[max(i - 1, 0)]).normalized()
            nrm = Vector((tan.y, -tan.x))  # right-hand side: outside of the recurve
            t = (i0 + i) / (len(half) - 1)
            rn = limb_r(t)[0]
            outer.append(p + nrm * (rn + 0.012))
        right = [(0.0, p.y, p.x) for p in outer]
        left = [(0.0, p.y, -p.x) for p in reversed(outer)]
        tube(b, left + right, 0.022, string_color, segments=5)
    return half


def fist(b, color, scale=1.0, top=0.66):
    """Rounded-square armored fist block, knuckles toward +Y."""
    s = scale
    b.loft([(0, -0.52, 0, 0.47 * s, 0.5 * s), (0, -0.12, 0, 0.52 * s, 0.55 * s), (0, 0.4, 0, 0.52 * s, 0.56 * s),
            (0, top - 0.06, 0, 0.45 * s, 0.5 * s), (0, top, 0, 0.32 * s, 0.4 * s)], color, power=3.2, segments=16)


def cuff(b, color, rim, scale=1.0, y0=-0.52, y1=-1.06, flare=1.18):
    s = scale
    b.loft([(0, y0, 0, 0.47 * s, 0.5 * s), (0, y1 + 0.06, 0, 0.47 * s * flare, 0.5 * s * flare)], color,
           power=3.0, segments=16)
    b.loft([(0, y1 + 0.1, 0, 0.49 * s * flare, 0.52 * s * flare), (0, y1, 0, 0.5 * s * flare, 0.53 * s * flare)],
           rim, power=3.0, segments=16)


# Base set ---------------------------------------------------------------------


def sword(b, g):
    b.sphere((0, -0.69, 0), (0.17, 0.14, 0.17), "steel_mid", segments=12, rings=8)
    b.cylinder((0, -0.56, 0), 0.1, 0.12, "steel_dark", segments=10)
    wrapped_grip(b, -0.52, 0.62, 0.115, "leather", "leather_dark")
    b.box((0, 0.72, 0), (0.24, 0.2, 1.3), "steel_mid", bevel=0.06)
    for s in (-1, 1):
        b.sphere((0, 0.72, s * 0.68), 0.12, "steel_mid", segments=10, rings=7)
    b.box((0, 0.74, 0), (0.3, 0.3, 0.44), "steel_dark", bevel=0.06)
    straight_blade(b, [(0.82, 0.25, 1.0), (1.6, 0.245, 1.0), (2.6, 0.235, 0.95), (3.6, 0.225, 0.9),
                       (4.3, 0.21, 0.85), (4.65, 0.15, 0.7), (4.88, 0.07, 0.5), (5.0, 0.0, 0.3)],
                   SYM, ["steel_hi", "steel", "steel", "steel_hi"])
    b.box((0, 2.3, 0), (0.15, 2.6, 0.08), "steel_mid", bevel=0.02, segments=1)


def hammer(b, g):
    b.cylinder((0, 1.4, 0), 0.15, 4.4, "wood", segments=10)
    wrapped_grip(b, -0.6, 0.6, 0.165, "leather", "leather_dark")
    b.cylinder((0, -0.86, 0), 0.2, 0.16, "steel_mid", segments=10)
    b.sphere((0, -0.95, 0), (0.16, 0.08, 0.16), "steel_mid", segments=10, rings=6)
    for s in (-1, 1):
        b.box((s * 0.15, 2.55, 0), (0.06, 0.8, 0.16), "steel_mid", bevel=0.02, segments=1)
    b.cylinder((0, 2.95, 0), 0.22, 0.14, "steel_dark", segments=10)
    b.box((0, 3.7, 0), (1.2, 1.4, 2.3), "steel_mid", bevel=0.1)
    for s in (-1, 1):
        b.box((0, 3.7, s * 1.3), (1.42, 1.62, 0.34), "steel", bevel=0.08)
        b.box((0, 3.7, s * 0.72), (1.28, 1.5, 0.14), "steel_dark", bevel=0.04)
    b.box((0, 4.44, 0), (0.36, 0.08, 0.36), "steel_dark", bevel=0.02)


def spear(b, g):
    b.cylinder((0, 2.35, 0), 0.11, 6.8, "wood", segments=10)
    wrapped_grip(b, -0.45, 0.45, 0.125, "leather", "leather_dark")
    wrapped_grip(b, 2.7, 3.3, 0.125, "leather", "leather_dark")
    b.cylinder((0, -1.1, 0), 0.13, 0.2, "steel_mid", segments=10, radius_top=0.12)
    b.cylinder((0, -1.26, 0), 0.06, 0.12, "steel_mid", segments=10, radius_top=0.13)
    b.cylinder((0, 5.82, 0), 0.115, 0.5, "steel_mid", segments=10, radius_top=0.15)
    b.torus((0, 5.64, 0), 0.125, 0.03, "steel_dark", segments=12, sides=4)
    straight_blade(b, [(6.02, 0.12, 1.0), (6.25, 0.3, 1.0), (6.45, 0.35, 1.0), (6.75, 0.3, 0.9),
                       (7.05, 0.17, 0.7), (7.35, 0.0, 0.3)],
                   SYM, ["steel_hi", "steel", "steel", "steel_hi"])


def gauntlets(b, g):
    fist(b, "steel")
    # overlapping plates on the back of the hand, each with a dark lower lip
    for y, w in ((0.3, 1.0), (0.06, 0.96), (-0.18, 0.92)):
        b.box((0, y, 0), (1.07, 0.2, w), "steel", bevel=0.05, taper=(1.0, 0.96))
        b.box((0, y - 0.11, 0), (1.08, 0.035, w - 0.04), "steel_dark", bevel=0.012, segments=1)
    b.box((0, 0.5, 0), (1.06, 0.05, 1.0), "steel_dark", bevel=0.015, segments=1)
    for z in (-0.39, -0.13, 0.13, 0.39):
        b.box((0, 0.64, z), (0.98, 0.24, 0.23), "steel_mid", bevel=0.09)
    b.capsule((0, -0.1, 0.56), (0, 0.32, 0.5), 0.14, "steel_mid", segments=10)
    b.loft([(0, -0.48, 0, 0.5, 0.53), (0, -0.6, 0, 0.5, 0.53)], "steel_dark", power=3.0, segments=16)
    cuff(b, "leather", "steel_mid", y0=-0.6)


def scythe(b, g):
    b.cylinder((0, 2.175, 0), 0.11, 6.35, "wood", segments=10)
    b.cylinder((0, -1.0, 0), 0.13, 0.16, "steel_mid", segments=10)
    wrapped_grip(b, -0.4, 0.45, 0.125, "leather", "leather_dark")
    # side handle (the nib)
    b.cylinder((0, 2.6, 0), 0.14, 0.18, "steel_dark", segments=10)
    tube(b, [(0, 2.6, 0.1), (0, 2.68, 0.35), (0, 2.8, 0.55)], [0.07, 0.07, 0.065], "wood_dark", segments=8)
    b.cylinder((0, 5.2, 0), 0.15, 0.32, "steel_dark", segments=10)
    b.box((0, 5.32, -0.05), (0.22, 0.36, 0.42), "steel_dark", bevel=0.05)
    lines = blade_lines([(0.0, 5.32), (-1.0, 5.5), (-2.2, 5.33), (-3.2, 4.9), (-3.72, 4.38)],
                        [(0, 0.17, 0.22), (0.06, 0.165, 0.29), (0.16, 0.16, 0.34), (0.5, 0.12, 0.3),
                         (0.85, 0.07, 0.16), (1, 0, 0)],
                        samples=5, thick=[(0, 1.0), (0.8, 0.8), (1, 0.4)])
    blade(b, lines, SINGLE, ["steel_mid", "steel", "steel_hi"])


def base_bow(b, g):
    half = [(0.0, 0.06), (0.5, 0.03), (1.1, -0.12), (1.62, -0.36), (2.0, -0.58), (2.25, -0.75)]

    def r(t):
        if t < 0.22:
            return (0.15, 0.15)
        return (0.11 - 0.06 * (t - 0.22) / 0.78, 0.14 - 0.07 * (t - 0.22) / 0.78)

    bow(b, half, r, "wood", "wood")
    wrapped_grip_z(b, -0.32, 0.32, 0.17, "leather", "leather_dark", y=0.05)
    for s in (-1, 1):
        b.sphere((0, -0.77, s * 2.25), (0.07, 0.07, 0.07), "steel_mid", segments=8, rings=6)
        b.cylinder((0, 0.0, s * 0.55), 0.165, 0.08, "steel_mid", rotation=(90, 0, 0), segments=10)


def wrapped_grip_z(b, z0, z1, r, base, band, y=0.0, step=0.13, tilt=16):
    b.cylinder((0, y, (z0 + z1) / 2), r, z1 - z0, base, rotation=(90, 0, 0), segments=10)
    n = max(1, int(round((z1 - z0) / step)))
    for i in range(n):
        z = z0 + (i + 0.5) * (z1 - z0) / n
        b.torus((0, y, z), r, 0.022, band, rotation=(90 + tilt, 0, 0), segments=10, sides=4)


# Kestrel ------------------------------------------------------------------------


def kestrel_sword(b, g):
    """Curved cutlass with a brass knuckle-bow guard."""
    wrapped_grip(b, -0.6, 0.66, 0.11, "grip_black", "brass", step=0.11, thickness=0.016)
    b.sphere((0, -0.72, 0), (0.15, 0.13, 0.15), "brass", segments=12, rings=8)
    b.sphere((0, -0.84, 0), (0.06, 0.06, 0.06), "brass_dark", segments=8, rings=6)
    # guard plate, short curled quillon (+Z) and the knuckle bow (-Z, the edge side)
    b.box((0, 0.75, -0.05), (0.24, 0.17, 0.6), "brass", bevel=0.05)
    curve_tube(b, [(0, 0.76, 0.2), (0, 0.8, 0.42), (0, 0.72, 0.56), (0, 0.6, 0.56)], (0.05, 0.06), "brass",
               segments=8)
    b.sphere((0, 0.6, 0.56), 0.07, "brass", segments=8, rings=6)
    bow_pts = curve_tube(b, [(0, 0.76, -0.3), (0, 0.66, -0.55), (0, 0.38, -0.68), (0, 0.0, -0.7),
                             (0, -0.36, -0.6), (0, -0.6, -0.32), (0, -0.7, -0.06)],
                         (0.055, 0.085), "brass", segments=8)
    for z, y in ((-0.8, 0.12), (-0.79, -0.14), (-0.7, -0.38)):
        b.torus((0, y, z), 0.07, 0.024, "brass", rotation=FACING, segments=10, sides=4)
    # blade: widens toward a clipped tip that curves back to the spine side (+Z)
    lines = blade_lines([(0.0, 0.84), (0.0, 1.8), (0.07, 2.8), (0.22, 3.7), (0.45, 4.45), (0.7, 4.98)],
                        [(0, 0.17, 0.2), (0.45, 0.17, 0.24), (0.78, 0.17, 0.3), (0.9, 0.12, 0.24), (1, 0, 0)],
                        samples=5, thick=[(0, 1.0), (0.85, 0.8), (1, 0.4)])
    blade(b, lines, SINGLE, ["steel_mid", "steel", "steel_hi"])


def kestrel_bow(b, g):
    """Pale-wood recurve with teal grip wraps."""
    half = [(0.0, 0.07), (0.5, 0.04), (1.0, -0.1), (1.5, -0.36), (1.88, -0.64), (2.08, -0.76), (2.24, -0.68),
            (2.3, -0.52)]

    def r(t):
        if t < 0.2:
            return (0.15, 0.14)
        f = (t - 0.2) / 0.8
        return (0.1 - 0.05 * f, 0.13 - 0.06 * f)

    half_pts = bow(b, half, r, "pale_wood", "pale_wood", string_color="string", bridge=5)
    wrapped_grip_z(b, -0.36, 0.36, 0.165, "teal", "teal_dark", y=0.06)
    for s in (-1, 1):
        b.cylinder((0, 0.03, s * 0.44), 0.16, 0.06, "pale_wood_dark", rotation=(90, 0, 0), segments=10)
    # teal bands near the tips and dark nocks
    n = len(half_pts) - 1
    for idx in (int(n * 0.66),):
        p, q = half_pts[idx], half_pts[idx + 1]
        tan = (q - p).normalized()
        ang = math.degrees(math.atan2(tan.x, tan.y))
        rn, rx = r(idx / n)
        for s in (-1, 1):
            b.cylinder((0, p.y, s * p.x), max(rn, rx) + 0.02, 0.26, "teal", rotation=(s * ang, 0, 0), segments=8)
            b.torus((0, p.y, s * p.x), max(rn, rx) + 0.02, 0.018, "teal_dark", rotation=(s * ang, 0, 0),
                    segments=8, sides=4)
    tip = half_pts[-1]
    for s in (-1, 1):
        b.sphere((0, tip.y + 0.02, s * tip.x), 0.055, "leather_dark", segments=8, rings=6)


# Brann --------------------------------------------------------------------------


def brann_hammer(b, g):
    """Massive two-handed forge hammer: anvil-shaped iron head with glowing runes."""
    b.cylinder((0, 0.9, 0), 0.19, 4.2, "wood_dark", segments=10)
    wrapped_grip(b, -0.9, 0.6, 0.205, "leather", "leather_dark", step=0.16)
    for y in (1.25, 2.25):
        b.cylinder((0, y, 0), 0.23, 0.16, "forge_iron", segments=10)
    b.box((0, -1.13, 0), (0.52, 0.3, 0.52), "forge_iron", bevel=0.07)
    b.box((0, 2.82, 0), (0.6, 0.24, 0.6), "forge_iron_dark", bevel=0.05)
    # the anvil (side profile faces the camera); horn toward -Z
    body = [(-1.05, 4.58), (1.5, 4.58), (1.5, 3.98), (1.22, 3.86), (0.72, 3.8), (0.55, 3.56), (0.62, 3.3),
            (1.0, 3.13), (1.06, 2.92), (-1.06, 2.92), (-1.0, 3.13), (-0.62, 3.3), (-0.55, 3.56), (-0.72, 3.8),
            (-0.95, 3.95), (-1.05, 4.1)]
    b.prism(body, 1.25, "forge_iron", rotation=FLAT, bevel=0.06)
    tube(b, [(0, 4.3, -0.95), (0, 4.34, -1.4), (0, 4.44, -1.95)], [(0.27, 0.55), (0.17, 0.34), (0, 0)],
         "forge_iron", segments=8, smooth=False)
    b.box((0, 4.62, 0.22), (1.34, 0.1, 2.56), "forge_iron_light", bevel=0.03, segments=1)
    # rivets
    for s in (-1, 1):
        for z, y in ((1.3, 4.38), (1.3, 4.1), (0.82, 3.04), (-0.82, 3.04)):
            b.sphere((s * 0.63, y, z), (0.05, 0.06, 0.06), "forge_iron_light", segments=8, rings=5)
    # glowing runes on both faces
    for s in (-1, 1):
        for name, z in (("fehu", 0.78), ("dagaz", 0.1), ("algiz", -0.58)):
            rune(g, name, z, 4.2, 0.42, s * 0.635, "ember")
        g.box((s * 0.635, 3.04, 0), (0.05, 0.06, 1.2), "ember", bevel=0.015, segments=1)


def brann_gauntlets(b, g):
    """Riveted iron gauntlets with ember-orange knuckle plates."""
    fist(b, "forge_iron", scale=1.04)
    for s in (-1, 1):
        b.box((s * 0.5, 0.05, 0), (0.12, 0.72, 0.84), "forge_iron_dark", bevel=0.04)
        for z in (-0.33, 0.33):
            for y in (-0.22, 0.32):
                b.sphere((s * 0.57, y, z), (0.04, 0.055, 0.055), "forge_iron_light", segments=8, rings=5)
        rune(g, "ingwaz", 0.0, 0.05, 0.4, s * 0.565, "ember", width=0.055, depth=0.04)
    for z in (-0.41, -0.14, 0.14, 0.41):
        b.box((0, 0.66, z), (1.04, 0.3, 0.25), "ember_plate", bevel=0.07)
        b.box((0, 0.53, z), (1.06, 0.06, 0.22), "ember_dark", bevel=0.02, segments=1)
    b.capsule((0, -0.12, 0.6), (0, 0.32, 0.54), 0.15, "forge_iron_dark", segments=10)
    cuff(b, "forge_iron_dark", "forge_iron", scale=1.04, y0=-0.52, flare=1.22)
    for s in (-1, 1):
        for z in (-0.38, 0.0, 0.38):
            b.sphere((s * 0.6, -0.97, z), (0.045, 0.05, 0.05), "forge_iron_light", segments=8, rings=5)


# Yuki ---------------------------------------------------------------------------


def yuki_spear(b, g):
    """Slender spear: pale ice-crystal blade, white-wrapped shaft."""
    b.cylinder((0, 2.3, 0), 0.085, 6.7, "wrap_white", segments=10)
    wraps(b, -0.95, 5.6, 0.085, "wrap_shade", step=0.36, tilt=24, thickness=0.016, segments=8)
    b.cylinder((0, -1.06, 0), 0.11, 0.16, "silver", segments=10)
    crystal(g, (0, -1.1, 0), (0, -1.42, 0), 0.08, "ice", sides=6, shoulder=0.35)
    for y in (0.55, -0.55):
        b.cylinder((0, y, 0), 0.105, 0.08, "silver", segments=10)
    b.cylinder((0, 5.72, 0), 0.1, 0.3, "silver", segments=10, radius_top=0.13)
    b.torus((0, 5.88, 0), 0.13, 0.035, "silver_dark", segments=12, sides=4)
    for s in (-1, 1):
        b.prism([(s * 0.1, 5.62), (s * 0.34, 5.9), (s * 0.3, 6.06), (s * 0.1, 5.92)], 0.06, "silver",
                rotation=FLAT, bevel=0.01)
        crystal(g, (0, 5.95, s * 0.12), (0, 6.4, s * 0.36), 0.065, "ice_deep")
    straight_blade(g, [(5.9, 0.1, 0.9), (6.2, 0.2, 1.1), (6.6, 0.22, 1.15), (7.0, 0.16, 1.0), (7.42, 0.0, 0.5)],
                   [(0.0, 0.012), (0.5, 0.075), (1.0, 0.012)], ["ice", "ice_deep"])


def yuki_bow(b, g):
    """Silver-birch recurve with frosted crystal tips."""
    half = [(0.0, 0.07), (0.5, 0.04), (1.0, -0.12), (1.45, -0.4), (1.78, -0.66), (1.98, -0.78), (2.14, -0.72),
            (2.2, -0.58)]

    def r(t):
        if t < 0.2:
            return (0.14, 0.13)
        f = (t - 0.2) / 0.8
        return (0.095 - 0.045 * f, 0.12 - 0.055 * f)

    half_pts = bow(b, half, r, "birch", "birch", string_color="silver", bridge=5)
    wrapped_grip_z(b, -0.32, 0.32, 0.155, "frost_blue", "silver", y=0.06, step=0.11)
    for s in (-1, 1):
        b.cylinder((0, 0.04, s * 0.38), 0.15, 0.07, "silver", rotation=(90, 0, 0), segments=10)
        # frost growing out of the riser fittings
        crystal(g, (0, 0.1, s * 0.4), (0, 0.46, s * 0.6), 0.055, "ice")
        crystal(g, (0, 0.08, s * 0.44), (0, 0.27, s * 0.78), 0.04, "ice_deep")
    # birch bark marks
    n = len(half_pts) - 1
    marks = (0.3, 0.38, 0.47, 0.55, 0.63, 0.72)
    for k, f in enumerate(marks):
        i = int(n * f)
        p, q = half_pts[i], half_pts[i + 1]
        tan = (q - p).normalized()
        ang = math.degrees(math.atan2(tan.x, tan.y))
        rn = r(f)[0]
        off = (0.35 if k % 2 else -0.35) * rn
        nrm = Vector((-tan.y, tan.x))
        c = p + nrm * off
        for s in (-1, 1):
            b.box((0, c.y, s * c.x), (r(f)[1] * 2 + 0.02, 0.035, rn * 0.9), "birch_mark", bevel=0.008,
                  segments=1, rotation=(s * ang, 0, 0))
    # frosted crystal tips
    tip, prev = half_pts[-1], half_pts[-3]
    d = (tip - prev).normalized()
    for s in (-1, 1):
        base = (0, tip.y, s * tip.x)
        crystal(g, base, (0, tip.y + d.y * 0.42, s * (tip.x + d.x * 0.42)), 0.075, "ice")
        crystal(g, base, (0, tip.y + d.y * 0.22 + 0.12, s * (tip.x + d.x * 0.1 + 0.12)), 0.05, "ice_deep")
        crystal(g, base, (0, tip.y + d.y * 0.15 - 0.1, s * (tip.x + d.x * 0.25 + 0.08)), 0.045, "ice_deep")


# Moss ---------------------------------------------------------------------------


def moss_scythe(b, g):
    """Curved wooden scythe whose blade is a living vine set with green crystal."""
    shaft = [(0, -1.02, 0.04), (0, 0.4, -0.04), (0, 2.2, 0.07), (0, 3.9, 0.0), (0, 5.0, -0.12), (0, 5.42, -0.3)]
    curve_tube(b, shaft, lambda t: 0.125 - 0.025 * t, "moss_wood", samples=3, segments=9)
    b.sphere((0, -1.05, 0.04), 0.14, "moss_wood_dark", segments=10, rings=7)
    for y, z, r in ((1.35, 0.06, 0.11), (3.1, 0.06, 0.1)):
        b.sphere((0.0, y, z), (0.15, r, 0.15), "moss_wood_dark", segments=10, rings=6)
    for y, z in ((2.55, 0.1), (4.4, -0.06), (-0.75, 0.04)):
        for dx, dy, dz, rr in ((0.06, 0.02, 0.06, 0.11), (0.0, -0.1, 0.1, 0.08)):
            b.sphere((dx, y + dy, z + dz), rr, "moss", segments=7, rings=5)
    # vine grip wrap
    wraps(b, -0.42, 0.45, 0.12, "vine", step=0.14, tilt=24, thickness=0.03, segments=8)
    # the blade: a thick vine sweeping toward -Z with a crystal edge grown beneath it
    ctrl = [(-0.22, 5.4), (-1.1, 5.62), (-2.25, 5.42), (-3.25, 4.92), (-3.8, 4.3)]
    lines = blade_lines(ctrl, [(0, 0.0, 0.28), (0.15, 0.0, 0.44), (0.55, 0.0, 0.38), (0.85, 0.0, 0.21), (1, 0, 0)],
                        samples=5, thick=[(0, 1.2), (0.8, 1.0), (1, 0.5)])
    blade(g, lines, [(0.04, 0.03), (0.42, 0.075), (1.0, 0.012)], ["crystal_deep", "crystal"])
    spine_pts = spline(ctrl, 5)
    vine = [(0.0, p.y + 0.02, p.x) for p in spine_pts]
    tube(b, vine, lambda t: (0.11 * (1 - t) + 0.025, 0.12 * (1 - t) + 0.03), "vine", segments=8)
    # a thinner vine twisting around it
    twist = []
    for i, p in enumerate(spine_pts):
        a = i * 1.15
        rr = 0.1 * (1 - i / len(spine_pts)) + 0.03
        twist.append((math.sin(a) * rr, p.y + 0.02 + math.cos(a) * rr, p.x))
    tube(b, twist, lambda t: 0.035 * (1 - t) + 0.012, "vine_dark", segments=6)
    # knot where the vine grows out of the snath
    b.sphere((0, 5.38, -0.24), (0.17, 0.17, 0.2), "vine_dark", segments=8, rings=6)
    for y in (5.08, 5.22):
        b.torus((0, y, -0.2), 0.12, 0.035, "vine", rotation=(-20, 0, 0), segments=8, sides=4)
    # broad leaves on top of the vine, leaning toward the tip, and two crystal buds
    ts = arc_params(spine_pts)
    for t, lean, size in ((0.1, 0.55, 0.52), (0.33, -0.35, 0.46), (0.56, 0.6, 0.42), (0.78, 0.4, 0.32)):
        i = min(range(len(ts)), key=lambda k: abs(ts[k] - t))
        p = spine_pts[i]
        tan = (spine_pts[min(i + 1, len(ts) - 1)] - spine_pts[max(i - 1, 0)]).normalized()
        up = Vector((tan.y, -tan.x))
        d = (up * 0.85 + tan * lean).normalized()
        base = p + up * 0.06
        leaf(b, (base.x, base.y), (base.x + d.x * size, base.y + d.y * size), size * 0.3, bend=0.04)
    for t in (0.22, 0.46):
        i = min(range(len(ts)), key=lambda k: abs(ts[k] - t))
        p = spine_pts[i]
        crystal(g, (0, p.y + 0.05, p.x), (0, p.y + 0.32, p.x - 0.08), 0.06, "crystal")
        crystal(g, (0, p.y + 0.05, p.x), (0, p.y + 0.22, p.x + 0.12), 0.045, "crystal_deep")
    # leaves on the snath
    leaf(b, (0.07, 3.95), (0.45, 4.3), 0.12, bend=-0.03)
    leaf(b, (-0.06, 2.0), (-0.44, 2.3), 0.12, bend=0.03)


def moss_spear(b, g):
    """Bamboo spear with a carved stone tip and hanging feathers."""
    nodes = [-1.15, -0.25, 0.75, 1.75, 2.75, 3.75, 4.75, 5.75]
    for y0, y1 in zip(nodes, nodes[1:]):
        b.cylinder((0, (y0 + y1) / 2, 0), 0.105, y1 - y0, "bamboo", segments=10, radius_top=0.112)
        b.cylinder((0, y1, 0), 0.125, 0.07, "bamboo_dark", segments=10)
    b.cylinder((0, nodes[0], 0), 0.12, 0.08, "bamboo_dark", segments=10)
    wraps(b, -0.42, 0.45, 0.115, "twine", step=0.1, tilt=18, thickness=0.025)
    wraps(b, -1.1, -0.85, 0.11, "twine", step=0.08, tilt=0, thickness=0.025)
    b.cylinder((0, 5.88, 0), 0.115, 0.3, "bamboo", segments=10)
    # stone tip: chunky facets in two greys
    spine = [(0.13, 5.9), (0.3, 6.15), (0.37, 6.4), (0.3, 6.78), (0.17, 7.08), (0.0, 7.36)]
    edge = [(-0.13, 5.9), (-0.32, 6.12), (-0.35, 6.42), (-0.28, 6.8), (-0.15, 7.1), (0.0, 7.36)]
    blade_between(b, spine, edge, [(0.0, 0.03), (0.5, 0.1), (1.0, 0.03)], ["stone_light", "stone"],
                  [1.0, 1.0, 1.0, 0.9, 0.7, 0.4], cap="stone_dark")
    for s in (-1, 1):
        stroke(b, (0.0, 6.2), (0.0, 6.95), 0.05, 0.03, "stone_dark", x=s * 0.1)
        stroke(b, (0.0, 6.55), (0.16, 6.75), 0.04, 0.03, "stone_dark", x=s * 0.095)
        stroke(b, (0.0, 6.55), (-0.16, 6.75), 0.04, 0.03, "stone_dark", x=s * 0.095)
    wraps(b, 5.75, 6.08, 0.125, "twine", step=0.08, tilt=20, thickness=0.028)
    # feathers hanging from cords
    for z0, z1, y1, lean in ((0.08, 0.36, 5.35, 0.14), (-0.08, -0.38, 5.25, -0.16), (0.1, 0.2, 5.0, 0.05)):
        tube(b, [(0, 5.8, z0), (0, (5.8 + y1) / 2, (z0 + z1) / 2 + 0.03 * (1 if z1 > 0 else -1)), (0, y1 + 0.02, z1)],
             0.016, "twine", segments=5, caps=False)
        length = 1.05
        top, bottom = (z1, y1), (z1 + lean, y1 - length)
        mid = (z1 + lean * 0.7, y1 - length * 0.7)
        quill = blade_lines([top, bottom], [(0, 0.03, 0.03), (0.15, 0.1, 0.1), (0.62, 0.11, 0.11), (1, 0, 0)],
                            samples=6)
        # split the vane into a pale upper part and a russet tip
        sp, ed, tk = quill
        cut = int(len(sp) * 0.62)
        blade_between(b, sp[:cut + 1], ed[:cut + 1], [(0.0, 0.01), (0.5, 0.022), (1.0, 0.01)],
                      ["feather", "stone_light"], tk[:cut + 1])
        blade_between(b, sp[cut:], ed[cut:], [(0.0, 0.01), (0.5, 0.022), (1.0, 0.01)],
                      ["feather_tip", "ember_dark"], tk[cut:])
        tube(b, [(0, top[1] + 0.04, top[0]), (0, mid[1], mid[0])], 0.014, "wood_dark", segments=4)


# Vex ----------------------------------------------------------------------------


def vex_scythe(b, g):
    """Black-steel scythe with a glowing violet edge."""
    b.cylinder((0, 2.2, 0), 0.115, 6.4, "shadow", segments=6, smooth=False)
    wraps(b, -0.45, 0.5, 0.12, "shadow_mid", step=0.13, tilt=20, thickness=0.028, segments=6)
    for y in (1.6, 3.4):
        b.cylinder((0, y, 0), 0.15, 0.2, "shadow_light", segments=6, smooth=False, radius_top=0.12)
        gem(g, y, 0.0, 0.13, 0.05, "violet", sides=4, height=0.06)
    spike(b, (0, -0.95, 0), (0, -1.55, 0), 0.13, "shadow_light")
    b.cylinder((0, -0.95, 0), 0.15, 0.12, "shadow_mid", segments=6, smooth=False)
    # head: angular mount with a back spike
    b.box((0, 5.32, 0.0), (0.26, 0.5, 0.42), "shadow_mid", bevel=0.04, segments=1)
    b.prism([(0.1, 5.15), (0.62, 5.62), (0.66, 5.86), (0.12, 5.5)], 0.12, "shadow_light", rotation=FLAT,
            bevel=0.015)
    gem(g, 5.32, 0.0, 0.13, 0.08, "violet")
    lines = blade_lines([(0.05, 5.4), (-1.1, 5.7), (-2.4, 5.52), (-3.42, 4.98), (-3.98, 4.22)],
                        [(0, 0.2, 0.22), (0.12, 0.2, 0.4), (0.5, 0.15, 0.36), (0.85, 0.09, 0.2), (1, 0, 0)],
                        samples=6, thick=[(0, 1.1), (0.8, 0.85), (1, 0.4)])
    blade(b, lines, [(0.0, 0.05), (0.3, 0.06), (0.72, 0.034)], ["shadow_mid", "shadow"])
    blade(g, lines, [(0.7, 0.03), (1.0, 0.012)], ["violet"])
    # notches on the spine
    for t in (0.25, 0.42):
        i = int(len(lines[0]) * t)
        p = lines[0][i]
        b.prism([(p.x + 0.12, p.y - 0.05), (p.x - 0.02, p.y + 0.2), (p.x - 0.1, p.y - 0.05)], 0.08,
                "shadow_mid", rotation=FLAT, bevel=0.01)


def vex_gauntlets(b, g):
    """Clawed shadow gauntlets with violet gems."""
    fist(b, "shadow")
    for s in (-1, 1):
        b.prism([(0.42, -0.35), (0.0, 0.48), (-0.42, -0.35), (0.0, -0.1)], 0.1, "shadow_mid", center=(s * 0.5, 0, 0),
                rotation=FLAT, bevel=0.015)
    gem(g, 0.05, 0.0, 0.52, 0.13, "violet", sides=6, height=0.1)
    for z in (-0.38, -0.13, 0.13, 0.38):
        b.box((0, 0.62, z), (0.96, 0.24, 0.22), "shadow_mid", bevel=0.06)
        lines = blade_lines([(z, 0.66), (z - 0.03, 1.0), (z - 0.14, 1.38)],
                            [(0, 0.065, 0.065), (0.6, 0.045, 0.045), (1, 0, 0)], samples=4)
        blade(b, lines, [(0.0, 0.015), (0.5, 0.06), (1.0, 0.015)], ["shadow_light", "steel_mid"])
    b.capsule((0, -0.12, 0.56), (0, 0.3, 0.5), 0.14, "shadow_mid", segments=10)
    cuff(b, "shadow_mid", "shadow_light", y0=-0.52, flare=1.12)
    for s in (-1, 1):
        spike(b, (0, -0.8, s * 0.5), (0, -1.05, s * 0.82), 0.09, "shadow_light")
        spike(b, (0, -0.55, s * 0.5), (0, -0.62, s * 0.78), 0.08, "shadow_light")
    for s in (-1, 1):
        gem(g, -0.82, 0.0, 0.56, 0.07, "violet_deep", sides=4, height=0.06)


# Sol ----------------------------------------------------------------------------


def sun_disc(b, g, y, z, radius, depth, rays, ray_len, ray_width, ray_depth, glow_r):
    b.cylinder((0, y, z), radius, depth, "gold", rotation=FACING, segments=18)
    b.torus((0, y, z), radius, 0.05, "gold_dark", rotation=FACING, segments=18, sides=4)
    b.cylinder((0, y, z), radius * 0.68, depth + 0.06, "gold_light", rotation=FACING, segments=16)
    if glow_r:
        g.cylinder((0, y, z), glow_r, depth + 0.12, "sun_glow", rotation=FACING, segments=12)
        g.cylinder((0, y, z), glow_r * 0.5, depth + 0.16, "sun_core", rotation=FACING, segments=10)
    sun_rays(b, y, z, radius * 0.92, ray_len, rays, ray_width, ray_depth, "gold")


def sol_sword(b, g):
    """Broad golden longsword with a sun-disc crossguard."""
    wrapped_grip(b, -0.55, 0.5, 0.12, "wrap_white", "gold", step=0.13, thickness=0.018)
    sun_disc(b, g, -0.72, 0.0, 0.17, 0.16, range(0, 360, 45), 0.3, 0.06, 0.08, 0.07)
    # crossguard: sun disc with long rays along Z standing in for quillons
    sun_disc(b, g, 0.78, 0.0, 0.36, 0.24, [], 0, 0, 0, 0.14)
    sun_rays(b, 0.78, 0.0, 0.32, lambda a: 0.88 if a % 180 == 0 else 0.62, (0, 180), 0.13, 0.16, "gold")
    sun_rays(b, 0.78, 0.0, 0.32, 0.6, (-30, -60, -120, -150, 30, 150), 0.08, 0.12, "gold")
    sun_rays(b, 0.78, 0.0, 0.32, 0.5, (-90,), 0.06, 0.1, "gold_dark")
    straight_blade(b, [(1.06, 0.33, 1.0), (1.4, 0.36, 1.05), (2.5, 0.34, 1.0), (3.6, 0.32, 0.95), (4.4, 0.28, 0.9),
                       (4.8, 0.18, 0.75), (5.02, 0.08, 0.55), (5.15, 0.0, 0.3)],
                   [(0.0, 0.014), (0.16, 0.04), (0.5, 0.085), (0.84, 0.04), (1.0, 0.014)],
                   ["sun_core", "gold_light", "gold", "sun_core"])
    b.box((0, 2.75, 0), (0.18, 2.3, 0.08), "gold_dark", bevel=0.02, segments=1)
    b.cylinder((0, 1.42, 0), 0.13, 0.19, "gold_dark", rotation=FACING, segments=12)
    b.cylinder((0, 1.42, 0), 0.075, 0.21, "gold_light", rotation=FACING, segments=10)


def sol_hammer(b, g):
    """War hammer with a radiant gold sun head on a long white-wrapped haft."""
    b.cylinder((0, 0.95, 0), 0.13, 4.2, "wrap_white", segments=10)
    wraps(b, -1.0, 2.95, 0.13, "wrap_shade", step=0.24, tilt=22, thickness=0.02, segments=8)
    for y in (-1.08, 0.65, 1.9):
        b.cylinder((0, y, 0), 0.165, 0.12, "gold", segments=10)
    b.sphere((0, -1.2, 0), (0.17, 0.12, 0.17), "gold", segments=10, rings=7)
    b.cylinder((0, 2.95, 0), 0.19, 0.3, "gold_dark", segments=10, radius_top=0.24)
    yc = 3.75
    # striking ends along Z: blunt rays that taper out to round faces
    for s in (-1, 1):
        wide, narrow = 0.38, 0.29
        # local +Y points to +Z, so the inner (wide) end is the bottom for s > 0 and the top for s < 0
        b.cylinder((0, yc, s * 1.1), wide if s > 0 else narrow, 0.8, "gold", rotation=(90, 0, 0), segments=10,
                   radius_top=narrow if s > 0 else wide, smooth=False)
        b.cylinder((0, yc, s * 1.52), narrow + 0.03, 0.08, "gold_dark", rotation=(90, 0, 0), segments=10,
                   smooth=False)
    sun_disc(b, g, yc, 0.0, 0.86, 0.9, [], 0, 0, 0, 0.32)
    sun_rays(b, yc, 0.0, 0.78, lambda a: 1.42 if a == 90 else 1.3, (45, 90, 135, -45, -135), 0.24, 0.64, "gold")
    sun_rays(b, yc, 0.0, 0.78, 1.12, (22.5, 67.5, 112.5, 157.5, -22.5, -67.5, -112.5, -157.5), 0.13, 0.46,
             "gold_light")


# Definitions --------------------------------------------------------------------

Weapon = namedtuple("Weapon", "id base trail build")

WEAPONS = [
    Weapon("Sword", "Sword", ((0, 1, 0), (0, 4.8, 0)), sword),
    Weapon("Hammer", "Hammer", ((0, 2.5, 0), (0, 4.4, 0)), hammer),
    Weapon("Spear", "Spear", ((0, 4, 0), (0, 7.3, 0)), spear),
    Weapon("Gauntlets", "Gauntlets", ((0, 0, 0), (0, 0.9, 0)), gauntlets),
    Weapon("Scythe", "Scythe", ((0, 5, -0.5), (0, 4.6, -3.5)), scythe),
    Weapon("Bow", "Bow", ((0, 0, -1), (0, 0, 1)), base_bow),
    Weapon("KestrelSword", "Sword", ((0, 1, 0), (0, 4.75, 0.55)), kestrel_sword),
    Weapon("KestrelBow", "Bow", ((0, 0, -1), (0, 0, 1)), kestrel_bow),
    Weapon("BrannHammer", "Hammer", ((0, 2.6, 0), (0, 4.6, 0)), brann_hammer),
    Weapon("BrannGauntlets", "Gauntlets", ((0, 0, 0), (0, 0.95, 0)), brann_gauntlets),
    Weapon("YukiSpear", "Spear", ((0, 4, 0), (0, 7.4, 0)), yuki_spear),
    Weapon("YukiBow", "Bow", ((0, 0, -1), (0, 0, 1)), yuki_bow),
    Weapon("MossScythe", "Scythe", ((0, 5.1, -0.6), (0, 4.6, -3.6)), moss_scythe),
    Weapon("MossSpear", "Spear", ((0, 4, 0), (0, 7.35, 0)), moss_spear),
    Weapon("VexScythe", "Scythe", ((0, 5.2, -0.6), (0, 4.6, -3.8)), vex_scythe),
    Weapon("VexGauntlets", "Gauntlets", ((0, 0, 0), (0, 1.35, 0)), vex_gauntlets),
    Weapon("SolSword", "Sword", ((0, 1.1, 0), (0, 4.95, 0)), sol_sword),
    Weapon("SolHammer", "Hammer", ((0, 2.7, 0), (0, 4.9, 0)), sol_hammer),
]
WEAPON_BY_ID = {w.id: w for w in WEAPONS}
BASE_TYPES = ["Sword", "Hammer", "Spear", "Gauntlets", "Scythe", "Bow"]


# Build + export --------------------------------------------------------------------


def build_weapon(spec, palette, collection):
    """Returns (body, glow or None) objects named <Id>_Body / <Id>_Glow."""
    body = MeshBuilder(f"{spec.id}_Body", palette, space=RIG_TO_BLENDER)
    glow = MeshBuilder(f"{spec.id}_Glow", palette, space=RIG_TO_BLENDER)
    spec.build(body, glow)
    objects = [body.build(collection)]
    if glow.count:
        objects.append(glow.build(collection))
    return objects


def weapon_bounds(objects):
    """Weapon-frame bounding box (lo, hi) of the objects."""
    to_frame = RIG_TO_BLENDER.transposed()
    lo, hi = [math.inf] * 3, [-math.inf] * 3
    for obj in objects:
        for v in obj.data.vertices:
            p = to_frame @ (obj.matrix_world @ v.co)
            for i in range(3):
                lo[i] = min(lo[i], p[i])
                hi[i] = max(hi[i], p[i])
    return lo, hi


def export_weapon(spec, objects, markers):
    """Writes <Id>.fbx with the meshes renamed to Body / Glow."""
    saved = [(obj, obj.name, obj.data.name) for obj in objects]
    for obj in objects:
        role = "Glow" if obj.name.endswith("_Glow") else "Body"
        obj.name = role
        obj.data.name = role
    try:
        path = common.export_fbx(os.path.join(EXPORT_DIR, f"{spec.id}.fbx"), objects + markers,
                                 space=RIG_TO_BLENDER)
    finally:
        for obj, name, data_name in saved:
            obj.name = name
            obj.data.name = data_name
    return path


def build_all(names=None):
    """Builds every weapon (the preview sheet needs them all), exports the
    named ones (all when `names` is None), writes WeaponMeshes.luau and
    renders the preview sheet."""
    unknown = [n for n in names or [] if n not in WEAPON_BY_ID]
    if unknown:
        raise SystemExit(f"unknown weapon(s) {', '.join(unknown)}; use: {', '.join(WEAPON_BY_ID)}")
    wanted = set(names or WEAPON_BY_ID)

    common.reset_scene()
    palette = Palette("Weapons", COLORS)
    common.ensure_dir(EXPORT_DIR)
    palette.save(os.path.join(EXPORT_DIR, "Weapons_palette.png"))
    markers = common.add_markers(RIG_TO_BLENDER)

    built = []
    for spec in WEAPONS:
        col = bpy.data.collections.new(spec.id)
        bpy.context.scene.collection.children.link(col)
        objects = build_weapon(spec, palette, col)
        tris = sum(common.triangle_count(o) for o in objects)
        lo, hi = weapon_bounds(objects)
        size = ", ".join(f"{hi[i] - lo[i]:.2f}" for i in range(3))
        status = "ok" if tris <= MAX_TRIANGLES else f"OVER {MAX_TRIANGLES}"
        if spec.id in wanted:
            path = export_weapon(spec, objects, markers)
            print(f"[{spec.id}] {path} ({tris} triangles {status}, size {size}, glow={len(objects) > 1})")
        else:
            print(f"[{spec.id}] preview only ({tris} triangles {status})")
        built.append((spec, objects, (lo, hi)))

    write_weapon_meshes_luau(built)
    render_preview(built, markers, PREVIEW_PATH)
    over = [spec.id for spec, objects, _ in built if sum(common.triangle_count(o) for o in objects) > MAX_TRIANGLES]
    if over:
        raise SystemExit(f"over the {MAX_TRIANGLES} triangle budget: {', '.join(over)}")
    return built


# WeaponMeshes.luau --------------------------------------------------------------------


def _num(x):
    x = round(float(x), 3)
    text = f"{x:.3f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "", "0") else text


def _vec(v):
    return "{ " + ", ".join(_num(x) for x in v) + " }"


def write_weapon_meshes_luau(built):
    glows = {spec.id: len(objects) > 1 for spec, objects, _ in built}
    lines = [
        "--[[",
        "    GENERATED by art/blender/build.py from art/blender/weapons.py. Do not edit by hand.",
        "",
        "    One entry per weapon mesh (art/export/weapons/<Id>.fbx). Weapon frame, as in",
        "    WeaponModels: grip at the origin, the weapon points along +Y, its broad side",
        "    lies along Z. Positions are { x, y, z } in studs.",
        "",
        "      Base   the base weapon type the mesh replaces",
        "      Trail  the two points a swing trail runs between (base, tip)",
        "      Glow   the FBX has a \"Glow\" mesh to show as Neon (the rest is \"Body\")",
        "",
        "    Every FBX also carries Marker_Origin (grip), Marker_Up (+Y) and Marker_Front",
        "    (-Z), MarkerDistance studs apart, to undo importer scale and rotation. All",
        "    weapons share one texture: Weapons_palette.png.",
        "]]",
        "",
        "return {",
        f"\tMarkerDistance = {_num(common.MARKER_DISTANCE)},",
        "\tWeapons = {",
    ]
    for spec in WEAPONS:
        a, b = spec.trail
        glow = "true" if glows.get(spec.id) else "false"
        lines.append(f'\t\t{spec.id} = {{ Base = "{spec.base}", Trail = {{ {_vec(a)}, {_vec(b)} }}, Glow = {glow} }},')
    lines += ["\t},", "}", ""]
    with open(LUAU_PATH, "w") as f:
        f.write("\n".join(lines))
    print(f"wrote {LUAU_PATH} ({len(WEAPONS)} weapons)")
    return LUAU_PATH


# Preview sheet --------------------------------------------------------------------

COLUMNS = 6
PREVIEW_WIDTH = 2016
CELL_W, CELL_H = 5.6, 10.0
PREVIEW_SCALE = {"Gauntlets": 2.0}  # small weapons are drawn bigger (and labeled so)
LIGHT_FROM = (-0.62, -0.55, 0.56)  # preview light: upper left, toward the camera (Blender axes, camera looks +Y)


def _flat_material(name, color):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    emit = nt.nodes.new("ShaderNodeEmission")
    emit.inputs["Color"].default_value = (*color, 1)
    nt.links.new(emit.outputs[0], out.inputs[0])
    return mat


def _glow_material(image):
    mat = bpy.data.materials.new("PreviewGlow")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.interpolation = "Closest"
    emit = nt.nodes.new("ShaderNodeEmission")
    emit.inputs["Strength"].default_value = 1.15
    nt.links.new(tex.outputs["Color"], emit.inputs["Color"])
    nt.links.new(emit.outputs[0], out.inputs[0])
    return mat


def _toon_material(image, light_from, threshold=0.4, shadow=(0.66, 0.66, 0.76)):
    """Cel shading from a fixed light direction (independent of the world
    light): palette color, darkened where N.L falls under `threshold`."""
    mat = bpy.data.materials.new("PreviewToonWeapons")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.interpolation = "Closest"
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    dot = nt.nodes.new("ShaderNodeVectorMath")
    dot.operation = "DOT_PRODUCT"
    dot.inputs[1].default_value = Vector(light_from).normalized()
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "CONSTANT"
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (*shadow, 1)
    ramp.color_ramp.elements[1].position = threshold
    ramp.color_ramp.elements[1].color = (1, 1, 1, 1)
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.blend_type = "MULTIPLY"
    mix.inputs[0].default_value = 1.0
    emit = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(geo.outputs["Normal"], dot.inputs[0])
    nt.links.new(dot.outputs["Value"], ramp.inputs["Fac"])
    nt.links.new(tex.outputs["Color"], mix.inputs[6])
    nt.links.new(ramp.outputs["Color"], mix.inputs[7])
    nt.links.new(mix.outputs[2], emit.inputs["Color"])
    nt.links.new(emit.outputs[0], out.inputs[0])
    return mat


def render_preview(built, markers, path):
    """All weapons upright (+Y up) seen from the broad side, base set in the
    first row, then the legends' pairs."""
    for m in markers:
        m.hide_render = True
    image = bpy.data.images.get("Weapons_palette")
    glow_mat = _glow_material(image)
    toon_mat = _toon_material(image, LIGHT_FROM)
    label_mat = _flat_material("PreviewLabel", (0.13, 0.13, 0.17))
    rows = (len(built) + COLUMNS - 1) // COLUMNS
    for i, (spec, objects, (lo, hi)) in enumerate(built):
        scale = PREVIEW_SCALE.get(spec.base, 1.0)
        common.toon_preview_materials(objects, outline=0.045 / scale)
        for obj in objects:
            obj.data.materials[0] = glow_mat if obj.name.endswith("_Glow") else toon_mat
        row, col = divmod(i, COLUMNS)
        cx, cy = (col + 0.5) * CELL_W, -(row + 0.5) * CELL_H + 0.35
        # weapon -Z is screen right, +Y is up, the camera sees the weapon's +X face
        mid_z, mid_y = (lo[2] + hi[2]) / 2, (lo[1] + hi[1]) / 2
        holder = bpy.data.objects.new(f"Cell_{spec.id}", None)
        holder.location = (cx + scale * mid_z, 0, cy - scale * mid_y)
        holder.rotation_euler = (0, 0, math.radians(90))
        holder.scale = (scale, scale, scale)
        bpy.context.scene.collection.objects.link(holder)
        for obj in objects:
            obj.parent = holder
        label = bpy.data.curves.new(f"Label_{spec.id}", type="FONT")
        label.body = spec.id + (f"  (x{scale:g})" if scale != 1 else "")
        label.align_x = "CENTER"
        label.size = 0.42
        text = bpy.data.objects.new(f"Label_{spec.id}", label)
        text.data.materials.append(label_mat)
        text.location = (cx, -1, -(row + 1) * CELL_H + 0.45)
        text.rotation_euler = (math.radians(90), 0, 0)
        bpy.context.scene.collection.objects.link(text)

    width, height = COLUMNS * CELL_W, rows * CELL_H
    w = PREVIEW_WIDTH
    h = int(round(w * height / width / 2)) * 2
    common.setup_preview_render(path, w, h, background=(0.9, 0.9, 0.93))
    common.ortho_camera("PreviewCam", (width / 2, -60, -height / 2), (width / 2, 0, -height / 2), width)
    return common.render(path)
