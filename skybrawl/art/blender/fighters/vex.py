"""Vex, shadow rogue. Scythe + Gauntlets. Fast glass cannon.

A lean young man in a short, tattered deep-purple hooded cloak: glowing violet
eyes in the shadow of the hood, a dark scarf mask over nose and mouth, black
leather vest with crossed belts and silver buckles, wrapped forearms, slim
charcoal trousers with knee guards and soft black boots with silver toe caps.
"""

import math

import bmesh
from mathutils import Vector

from sky.rig import pivot, sides

NAME = "Vex"

COLORS = {
    "skin": "#f2dfd6",
    "eye_white": "#eadcff",
    "iris": "#b25cff",
    "iris_core": "#7b2fd6",
    "eye_hi": "#ffffff",
    "lash": "#140f1b",
    "brow": "#17121e",
    "hair": "#1c1924",
    "streak": "#a85eff",
    "hood": "#56308a",
    "hood_dark": "#3b1f5e",
    "cloak": "#47256f",
    "lining": "#1b1027",
    "scarf": "#2c2836",
    "scarf_dark": "#1e1b26",
    "shirt": "#353140",
    "vest": "#26232d",
    "vest_hi": "#38343f",
    "strap": "#4b4358",
    "silver": "#d0d4de",
    "silver_dark": "#8f94a4",
    "wrap": "#403a4c",
    "wrap_dark": "#2a2632",
    "pants": "#474a55",
    "guard": "#2e2b36",
    "boot": "#25222b",
    "boot_dark": "#19171e",
    "sole": "#121116",
    "knife_handle": "#3c2458",
}


# Helpers --------------------------------------------------------------------
# Extra primitives built straight into a part's MeshBuilder. Everything is in
# rig space; builder._finish() colors the faces and converts to Blender.


def _clip(tmp, planes):
    for point, normal in planes or ():
        geom = tmp.verts[:] + tmp.edges[:] + tmp.faces[:]
        bmesh.ops.bisect_plane(tmp, geom=geom, dist=1e-5, plane_co=Vector(point),
                               plane_no=Vector(normal).normalized(), clear_inner=True)


def _orient_out(tmp, axis_point):
    """Flips a whole open shell so its faces point away from a vertical axis."""
    total = 0.0
    for f in tmp.faces:
        c = f.calc_center_median()
        d = Vector((c.x - axis_point[0], 0.0, c.z - axis_point[2]))
        total += f.normal.dot(d) * f.calc_area()
    if total < 0:
        bmesh.ops.reverse_faces(tmp, faces=tmp.faces[:])


def _emit(builder, tmp, color, smooth=True):
    builder._finish(tmp, color, (0, 0, 0), None, smooth)


def _spow(v, e):
    return math.copysign(abs(v) ** e, v)


def grid_shell(builder, rows, color, thickness=0.04, closed=False, clip=None, axis=(0, 0, 0), smooth=True):
    """Cloth sheet through rows of points (every row the same length), clipped
    and then solidified inward so it is a closed solid (Roblox culls
    backfaces, so open sheets would vanish from behind)."""
    tmp = bmesh.new()
    vrows = [[tmp.verts.new(p) for p in row] for row in rows]
    n = len(rows[0])
    for r0, r1 in zip(vrows, vrows[1:]):
        for i in range(n if closed else n - 1):
            j = (i + 1) % n
            tmp.faces.new((r0[i], r0[j], r1[j], r1[i]))
    _clip(tmp, clip)
    _orient_out(tmp, axis)
    if thickness:
        bmesh.ops.solidify(tmp, geom=tmp.faces[:], thickness=thickness)
    _emit(builder, tmp, color, smooth)


def shell_loft(builder, sections, color, thickness=0.04, segments=20, power=2.0, clip=None, top_point=None):
    """Open loft (horizontal rings) clipped then solidified: hoods, cowls."""
    rows = []
    ex = 2.0 / power
    for x, y, z, rx, rz in sections:
        row = []
        for i in range(segments):
            a = 2 * math.pi * i / segments
            row.append((x + rx * _spow(math.cos(a), ex), y, z + rz * _spow(math.sin(a), ex)))
        rows.append(row)
    tmp = bmesh.new()
    vrows = [[tmp.verts.new(p) for p in row] for row in rows]
    for r0, r1 in zip(vrows, vrows[1:]):
        for i in range(segments):
            j = (i + 1) % segments
            tmp.faces.new((r0[i], r0[j], r1[j], r1[i]))
    if top_point is not None:
        tip = tmp.verts.new(top_point)
        last = vrows[-1]
        for i in range(segments):
            tmp.faces.new((last[i], last[(i + 1) % segments], tip))
    _clip(tmp, clip)
    _orient_out(tmp, (sections[0][0], 0, sections[0][2]))
    if thickness:
        bmesh.ops.solidify(tmp, geom=tmp.faces[:], thickness=thickness)
    _emit(builder, tmp, color)


def sweep(builder, path, radii, color, segments=10, normal_hint=(0, 1, 0), power=2.0, caps=True, smooth=True):
    """Tube along a polyline with elliptical sections. radii[i] = (w, h): w
    across the path (perpendicular to normal_hint), h along normal_hint. A
    zero radius makes a pointed end."""
    pts = [Vector(p) for p in path]
    hint = Vector(normal_hint).normalized()
    ex = 2.0 / power
    tmp = bmesh.new()
    rings = []
    for k, p in enumerate(pts):
        if k == 0:
            t = pts[1] - pts[0]
        elif k == len(pts) - 1:
            t = pts[-1] - pts[-2]
        else:
            t = (pts[k + 1] - pts[k]).normalized() + (pts[k] - pts[k - 1]).normalized()
        t.normalize()
        side = t.cross(hint)
        if side.length < 1e-4:
            side = t.cross(Vector((1, 0, 0)))
        side.normalize()
        nrm = side.cross(t).normalized()
        w, h = radii[k] if isinstance(radii[k], (tuple, list)) else (radii[k], radii[k])
        if w <= 1e-6 and h <= 1e-6:
            rings.append([tmp.verts.new(p)])
            continue
        ring = []
        for i in range(segments):
            a = 2 * math.pi * i / segments
            c, s_ = math.cos(a), math.sin(a)
            ring.append(tmp.verts.new(p + side * (w * _spow(c, ex)) + nrm * (h * _spow(s_, ex))))
        rings.append(ring)
    for r0, r1 in zip(rings, rings[1:]):
        if len(r0) == 1 or len(r1) == 1:
            tip, ring = (r0[0], r1) if len(r0) == 1 else (r1[0], r0)
            flip = len(r0) == 1
            for i in range(len(ring)):
                a, b = ring[i], ring[(i + 1) % len(ring)]
                tmp.faces.new((tip, b, a) if flip else (a, b, tip))
            continue
        for i in range(segments):
            j = (i + 1) % segments
            tmp.faces.new((r0[i], r0[j], r1[j], r1[i]))
    if caps and len(rings[0]) > 2:
        tmp.faces.new(list(reversed(rings[0])))
    if caps and len(rings[-1]) > 2:
        tmp.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
    _emit(builder, tmp, color, smooth)


def side_plate(builder, outline_zy, thickness, x, color, bevel=0.0, yaw=0.0):
    """Flat shape seen in the side view: outline [(z, y), ...], thin along X.
    `yaw` swings its far (+z) end toward +x (degrees)."""
    builder.prism(list(outline_zy), thickness, color, center=(x, 0, 0), rotation=(0, -90 + yaw, 0), bevel=bevel)


def surface_z(sections, x, y, power, back=False):
    """z of a loft's surface (front, or back) at (x, y). sections as in loft."""
    secs = sorted(sections, key=lambda s: s[1])
    if y <= secs[0][1]:
        s = secs[0]
    elif y >= secs[-1][1]:
        s = secs[-1]
    else:
        for s0, s1 in zip(secs, secs[1:]):
            if s0[1] <= y <= s1[1]:
                t = (y - s0[1]) / (s1[1] - s0[1])
                s = tuple(s0[i] + (s1[i] - s0[i]) * t for i in range(5))
                break
    cx, _, cz, rx, rz = s
    u = min(abs(x - cx) / rx, 0.999)
    dz = rz * (1 - u ** power) ** (1 / power)
    return cz + dz if back else cz - dz


# Head -----------------------------------------------------------------------

SKULL_C, SKULL_R = (0, 5.15, 0.0), (0.46, 0.55, 0.49)


def head(fb):
    h = fb["Head"]
    # neck, skull, jaw
    h.cylinder((0, 4.6, 0.02), 0.19, 0.4, "scarf", segments=10)
    h.sphere(SKULL_C, SKULL_R, "skin", segments=18, rings=12)
    h.sphere((0, 4.93, -0.07), (0.37, 0.31, 0.4), "skin", segments=14, rings=9)

    # eyes: big sharp almonds, glowing violet
    for _, s in sides():
        h.sphere((s * 0.2, 5.15, -0.45), (0.14, 0.085, 0.058), "eye_white", rotation=(0, -s * 18, s * 12),
                 segments=14, rings=8)
        h.sphere((s * 0.205, 5.145, -0.493), (0.085, 0.082, 0.035), "iris", rotation=(0, -s * 26, 0),
                 segments=12, rings=7)
        h.sphere((s * 0.212, 5.14, -0.52), (0.036, 0.05, 0.012), "iris_core", rotation=(0, -s * 26, 0),
                 segments=8, rings=5)
        h.sphere((s * 0.175, 5.178, -0.536), (0.024, 0.024, 0.008), "eye_hi", segments=6, rings=4)
        # upper lid line and a sharp scowling brow
        h.box((s * 0.21, 5.222, -0.485), (0.29, 0.035, 0.05), "lash", bevel=0.012, rotation=(0, 0, s * 14))
        h.box((s * 0.215, 5.315, -0.47), (0.27, 0.065, 0.07), "brow", bevel=0.02, rotation=(0, 0, s * 17))

    # scarf mask over nose and mouth, wrapped folds
    mask = [(0, 4.5, 0.02, 0.29, 0.31), (0, 4.62, -0.01, 0.36, 0.4), (0, 4.8, -0.04, 0.44, 0.48),
            (0, 4.97, -0.035, 0.48, 0.52), (0, 5.06, -0.03, 0.485, 0.525)]
    h.loft(mask, "scarf", segments=18, power=2.1)
    h.limb((0, 5.04, -0.5), (0, 4.94, -0.535), 0.055, 0.07, "scarf", segments=10)
    for y, rx, rz in ((4.72, 0.41, 0.45), (4.9, 0.465, 0.505)):
        h.loft([(0, y - 0.022, -0.04, rx, rz), (0, y + 0.022, -0.04, rx, rz)], "scarf_dark", segments=18,
               power=2.1)

    # hair under the hood: black cap, spiky fringe with a purple streak, side locks
    h.sphere((0, 5.2, 0.02), (0.48, 0.57, 0.51), "hair", segments=16, rings=10,
             clip=[((0, 5.42, -0.42), (0, 1.0, 0.6))])
    fringe = (
        # root (x, y, z), tip (x, y, z), base width, color
        ((-0.02, 5.62, -0.36), (0.02, 5.17, -0.6), 0.1, "streak"),
        ((-0.2, 5.62, -0.35), (-0.27, 5.37, -0.6), 0.085, "hair"),
        ((0.2, 5.62, -0.35), (0.26, 5.38, -0.6), 0.085, "hair"),
        ((-0.34, 5.58, -0.3), (-0.47, 5.3, -0.47), 0.085, "hair"),
        ((0.34, 5.58, -0.3), (0.47, 5.3, -0.47), 0.085, "hair"),
        ((-0.42, 5.46, -0.2), (-0.47, 4.98, -0.13), 0.075, "hair"),
        ((0.42, 5.46, -0.2), (0.47, 4.98, -0.13), 0.075, "hair"),
    )
    for (x, y, z), (tx, ty, tz), w, col in fringe:
        mid = ((x + tx) / 2, (y + ty) / 2 + 0.04, (z + tz) / 2 - 0.05)
        sweep(h, [(x, y, z), mid, (tx, ty, tz)], [(w, w * 0.5), (w * 0.75, w * 0.4), (0, 0)], col, segments=8,
              normal_hint=(0, 0.3, -1))

    # the hood: open in front with a pointed brim, peak drooping behind, dark lining
    def opening(dz):
        return [((0, 5.22, -0.3 + dz), (0.32, 0.8, 1.0)), ((0, 5.22, -0.3 + dz), (-0.32, 0.8, 1.0))]

    hood = [(0, 4.55, 0.1, 0.46, 0.5), (0, 4.78, 0.07, 0.56, 0.6), (0, 5.1, 0.05, 0.61, 0.645),
            (0, 5.45, 0.07, 0.6, 0.635), (0, 5.7, 0.12, 0.51, 0.55), (0, 5.86, 0.2, 0.31, 0.37)]
    shell_loft(h, hood, "hood", thickness=0.05, segments=22, power=2.1, clip=opening(0.0),
               top_point=(0, 5.93, 0.26))
    lining = [(x, y, z + 0.02, rx - 0.05, rz - 0.05) for x, y, z, rx, rz in hood[:-1]]
    shell_loft(h, lining, "lining", thickness=0.03, segments=22, power=2.1, clip=opening(0.035),
               top_point=(0, 5.8, 0.2))
    # peak, lying flat down the back of the hood
    sweep(h, [(0, 5.8, 0.3), (0, 5.73, 0.6), (0, 5.5, 0.82), (0, 5.1, 0.88)],
          [(0.3, 0.2), (0.21, 0.14), (0.12, 0.08), (0, 0)], "hood", segments=12, normal_hint=(0, 1, 0))


# Torso ------------------------------------------------------------------------

VEST = [(0, 3.02, 0.0, 0.47, 0.33), (0, 3.4, 0.0, 0.51, 0.35), (0, 3.9, 0.0, 0.58, 0.37),
        (0, 4.22, 0.0, 0.59, 0.35), (0, 4.42, 0.0, 0.44, 0.28)]
VEST_POWER = 2.4


def _strap(builder, pts2d, back, color, width=0.06, thick=0.025, lift=0.02):
    path = []
    for x, y in pts2d:
        z = surface_z(VEST, x, y, VEST_POWER, back=back)
        path.append((x, y, z + (lift if back else -lift)))
    sweep(builder, path, [(width, thick)] * len(path), color, segments=8, power=6,
          normal_hint=(0, 0, 1 if back else -1))


def _capelet_rows(rings, hem, columns, open_deg):
    """Rows of a front-open shoulder cape. rings: (y, rx, rz, cz, open_deg).
    hem: (y_front, y_back, rx, rz, cz, tooth). Zig-zag teeth on the hem."""
    rows = []
    ex = 2.0 / 2.6
    for y, rx, rz, cz, op in rings:
        row = []
        a0 = math.radians(op)
        for i in range(columns + 1):
            th = a0 + (2 * math.pi - 2 * a0) * i / columns
            row.append((rx * _spow(math.sin(th), ex), y, cz - rz * _spow(math.cos(th), ex)))
        rows.append(row)
    yf, yb, rx, rz, cz, tooth = hem
    row = []
    a0 = math.radians(open_deg)
    for i in range(columns + 1):
        th = a0 + (2 * math.pi - 2 * a0) * i / columns
        back = (1 - math.cos(th)) / 2
        y = yf + (yb - yf) * back ** 2.2
        grow = 1.0
        if i % 2 == 1:
            y -= tooth * (0.6 + 0.8 * abs(math.sin(i * 2.17)))
            grow = 1.07
        row.append((rx * grow * _spow(math.sin(th), ex), y, cz - rz * grow * _spow(math.cos(th), ex)))
    rows.append(row)
    return rows


def _tail_rows(rings, hem, cols, tooth):
    """Back-only cloak panel: rings (y, rx, rz, cz, a0, a1) in degrees around
    the body (180 = straight behind); hem (y_mid, y_edge, rx, rz, cz, a0, a1)."""
    rows = []
    for y, rx, rz, cz, a0, a1 in rings:
        row = []
        for i in range(cols + 1):
            th = math.radians(a0 + (a1 - a0) * i / cols)
            row.append((rx * math.sin(th), y, cz - rz * math.cos(th)))
        rows.append(row)
    ym, ye, rx, rz, cz, a0, a1 = hem
    row = []
    for i in range(cols + 1):
        u = i / cols
        th = math.radians(a0 + (a1 - a0) * u)
        y = ye + (ym - ye) * math.sin(math.pi * u)
        g = 1.0
        if i % 2 == 1:
            y -= tooth * (0.7 + 0.6 * abs(math.sin(i * 1.93)))
            g = 1.05
        row.append((rx * g * math.sin(th), y, cz - rz * g * math.cos(th)))
    rows.append(row)
    return rows


def torso(fb):
    up = fb["UpperTorso"]
    # undershirt and fitted black leather vest
    up.loft([(0, 3.0, 0, 0.45, 0.31), (0, 3.9, 0, 0.56, 0.35), (0, 4.4, 0, 0.42, 0.27)], "shirt", power=2.4,
            segments=16)
    up.loft(VEST, "vest", power=VEST_POWER, segments=18)
    # vest closure seam and lower hem
    _strap(up, [(0.02, 3.05), (0.03, 4.3)], False, "vest_hi", width=0.025, thick=0.02, lift=0.0)
    up.loft([(0, 3.02, 0, 0.485, 0.345), (0, 3.1, 0, 0.495, 0.35)], "vest_hi", power=VEST_POWER, segments=18)
    # crossed belts, front and back, silver buckles
    for back in (False, True):
        _strap(up, [(-0.5, 4.2), (-0.2, 3.85), (0.15, 3.42), (0.4, 3.1)], back, "strap")
        _strap(up, [(0.5, 4.2), (0.2, 3.85), (-0.15, 3.42), (-0.4, 3.1)], back, "strap", lift=0.035)
    up.torus((0, 3.64, -0.4), 0.07, 0.025, "silver", rotation=(90, 0, 0), segments=12, sides=6)
    up.sphere((0, 3.64, -0.405), (0.04, 0.04, 0.02), "iris", segments=8, rings=5)
    for x, y in ((-0.3, 3.95), (0.3, 3.95)):
        z = surface_z(VEST, x, y, VEST_POWER) - 0.05
        up.box((x, y, z), (0.11, 0.1, 0.03), "silver", bevel=0.015)
        up.box((x, y, z - 0.012), (0.05, 0.05, 0.02), "vest", bevel=0.005)

    # short hooded cloak: front-open capelet over the shoulders, tattered hem
    rings = [(4.64, 0.37, 0.36, 0.04, 10), (4.5, 0.64, 0.45, 0.03, 17), (4.36, 1.07, 0.5, 0.03, 34),
             (4.18, 1.27, 0.52, 0.03, 44), (3.97, 1.32, 0.54, 0.05, 52)]
    hem = (3.8, 3.2, 1.35, 0.57, 0.07, 0.22)
    rows = _capelet_rows(rings, hem, 40, 60)
    grid_shell(up, rows, "cloak", thickness=0.04)
    for col in (7, 13, 27, 33):
        path = []
        for k in range(2, len(rows)):
            x, y, z = rows[k][col]
            d = Vector((x, 0, z - 0.05)).normalized()
            path.append((x + d.x * 0.008, y + (0.06 if k == len(rows) - 1 else 0.0), z + d.z * 0.008))
        n = len(path)
        sweep(up, path, [(0.022 * (1 - 0.5 * k / (n - 1)), 0.012) for k in range(n)], "hood_dark", segments=6,
              normal_hint=(path[1][0], 0, path[1][2] - 0.05))
    # clasp at the throat
    up.cylinder((0, 4.52, -0.43), 0.075, 0.05, "silver", rotation=(90, 0, 0), segments=12)
    up.sphere((0, 4.52, -0.458), (0.045, 0.045, 0.025), "iris", segments=8, rings=5)
    for _, s in sides():
        up.box((s * 0.13, 4.52, -0.41), (0.14, 0.04, 0.03), "silver", bevel=0.01, rotation=(0, s * 14, 0))

    # scarf tails trailing from the back of the neck
    up.sphere((0, 4.56, 0.44), (0.14, 0.11, 0.1), "scarf", segments=10, rings=7)
    side_plate(up, [(0.4, 4.62), (0.7, 4.56), (1.0, 4.38), (1.25, 4.2), (1.45, 3.96), (1.22, 4.02), (1.3, 3.83),
                    (1.0, 4.1), (0.72, 4.32), (0.42, 4.46)], 0.05, 0.04, "scarf", yaw=10)
    side_plate(up, [(0.42, 4.5), (0.62, 4.36), (0.85, 4.06), (0.98, 3.76), (0.8, 3.87), (0.78, 3.7),
                    (0.66, 3.98), (0.48, 4.28)], 0.05, -0.05, "scarf_dark", yaw=-14)

    low = fb["LowerTorso"]
    low.loft([(0, 2.35, 0, 0.5, 0.36), (0, 2.65, 0, 0.53, 0.37), (0, 2.95, 0, 0.5, 0.35), (0, 3.15, 0, 0.46, 0.32)],
             "pants", power=2.3, segments=16)
    # belt with silver buckle
    low.loft([(0, 2.86, 0, 0.535, 0.375), (0, 2.98, 0, 0.53, 0.37)], "vest", power=2.4, segments=18)
    low.box((0, 2.92, -0.38), (0.17, 0.14, 0.04), "silver", bevel=0.02)
    low.box((0, 2.92, -0.4), (0.09, 0.07, 0.02), "vest", bevel=0.01)
    # slung knife belt, low on the left hip, three throwing knives
    low.loft([(0, -0.055, 0, 0.565, 0.405), (0, 0.055, 0, 0.565, 0.405)], "strap", power=2.4, segments=18,
             center=(0, 2.68, 0), rotation=(0, 0, -9))
    for k, (x, ang) in enumerate(((-0.24, -8), (-0.38, -10), (-0.5, -12))):
        y = 2.68 + 0.16 * (-x) * 0.9 - 0.02
        z = -0.4 + 0.07 * k
        low.box((x, y - 0.1, z), (0.07, 0.2, 0.05), "vest", bevel=0.012, rotation=(0, 0, ang))
        low.box((x - 0.012, y + 0.06, z - 0.005), (0.04, 0.14, 0.035), "knife_handle", bevel=0.01,
                rotation=(0, 0, ang))
        low.torus((x - 0.025, y + 0.17, z - 0.005), 0.035, 0.012, "silver", rotation=(90, 0, ang), segments=8,
                  sides=4)

    # cloak tails behind, tattered, longest in the middle
    tail = _tail_rows([(3.3, 0.5, 0.42, 0.0, 122, 238), (2.8, 0.6, 0.5, 0.06, 124, 236),
                       (2.35, 0.67, 0.58, 0.12, 126, 234)],
                      (2.0, 2.24, 0.72, 0.64, 0.16, 128, 232), 16, 0.22)
    grid_shell(low, tail, "cloak", thickness=0.035)


# Arms ---------------------------------------------------------------------------


def arms(fb):
    for side, s in sides():
        ua = fb[f"{side}UpperArm"]
        sh = pivot(f"{side}Shoulder")
        el = pivot(f"{side}Elbow")
        a, b = (sh[0] - s * 0.02, sh[1] - 0.12, 0), (el[0], el[1] + 0.04, 0)
        ua.sphere((s * 0.97, 4.08, 0), (0.22, 0.22, 0.23), "shirt", segments=14, rings=9)
        ua.limb(a, b, 0.195, 0.18, "shirt")

        la = fb[f"{side}LowerArm"]
        wr = pivot(f"{side}Wrist")
        la.limb(el, (wr[0], wr[1] + 0.06, 0), 0.18, 0.165, "wrap")
        for k, y in enumerate((2.74, 2.9, 3.06, 3.2)):
            t = (el[1] - y) / (el[1] - wr[1])
            x = el[0] + (wr[0] - el[0]) * t
            r = 0.18 + (0.165 - 0.18) * t + 0.012
            la.loft([(0, -0.03, 0, r, r), (0, 0.03, 0, r, r)], "wrap_dark", segments=12, center=(x, y, 0),
                    rotation=(18 if k % 2 else -18, 0, s * 6))
        la.loft([(0, -0.035, 0, 0.185, 0.185), (0, 0.035, 0, 0.19, 0.19)], "silver", segments=12,
                center=(s * 1.215, 3.27, 0))

        hand = fb[f"{side}Hand"]
        hand.box((wr[0] + s * 0.04, 2.33, -0.02), (0.32, 0.44, 0.38), "skin", bevel=0.11, segments=2)
        hand.box((wr[0] + s * 0.05, 2.17, -0.1), (0.3, 0.16, 0.26), "skin", bevel=0.07)
        hand.limb((wr[0] - s * 0.11, 2.45, -0.15), (wr[0] - s * 0.13, 2.27, -0.23), 0.075, 0.065, "skin",
                  segments=8)
        # wraps over the back of the hand
        hand.box((wr[0] + s * 0.04, 2.47, -0.02), (0.35, 0.14, 0.41), "wrap", bevel=0.05)
        hand.box((wr[0] + s * 0.04, 2.565, -0.0), (0.31, 0.06, 0.35), "wrap_dark", bevel=0.025)


# Legs ---------------------------------------------------------------------------


def legs(fb):
    for side, s in sides():
        ul = fb[f"{side}UpperLeg"]
        ul.loft([(s * 0.42, 2.86, 0, 0.17, 0.2), (s * 0.48, 2.66, 0, 0.29, 0.31), (s * 0.52, 2.15, 0, 0.28, 0.3),
                 (s * 0.52, 1.58, 0, 0.225, 0.245)], "pants", segments=14)
        if s > 0:
            ul.loft([(s * 0.52, 2.0, 0, 0.29, 0.305), (s * 0.52, 2.09, 0, 0.295, 0.31)], "vest", segments=14)
            ul.box((s * 0.81, 2.045, -0.02), (0.04, 0.1, 0.1), "silver", bevel=0.012)

        ll = fb[f"{side}LowerLeg"]
        ll.loft([(s * 0.52, 1.6, 0, 0.225, 0.245), (s * 0.52, 1.35, 0, 0.23, 0.25), (s * 0.52, 1.08, 0, 0.21, 0.23)],
                "pants", segments=14)
        # knee guard
        ll.prism([(-0.17, 0.13), (0.17, 0.13), (0.2, -0.04), (0.0, -0.24), (-0.2, -0.04)], 0.1, "guard",
                 center=(s * 0.52, 1.5, -0.24), rotation=(-8, 0, 0), bevel=0.025)
        ll.sphere((s * 0.52, 1.5, -0.3), (0.045, 0.045, 0.02), "silver", segments=8, rings=5)
        # soft boots with a folded cuff and a buckled strap
        ll.loft([(s * 0.52, 0.42, 0.02, 0.2, 0.23), (s * 0.52, 0.8, 0.0, 0.215, 0.24),
                 (s * 0.52, 1.08, 0.0, 0.23, 0.25)], "boot", segments=14)
        ll.loft([(s * 0.52, 0.98, 0, 0.245, 0.265), (s * 0.52, 1.14, 0, 0.26, 0.28)], "boot", segments=14)
        ll.loft([(s * 0.52, 0.95, 0, 0.24, 0.26), (s * 0.52, 0.99, 0, 0.245, 0.265)], "boot_dark", segments=14)
        ll.loft([(s * 0.52, 0.64, 0.0, 0.222, 0.248), (s * 0.52, 0.72, 0.0, 0.225, 0.25)], "boot_dark", segments=14)
        ll.box((s * 0.735, 0.68, -0.02), (0.04, 0.09, 0.09), "silver", bevel=0.012)

        ft = fb[f"{side}Foot"]
        ft.box((s * 0.52, 0.26, -0.1), (0.4, 0.44, 0.78), "boot", bevel=0.15, segments=2, taper=(0.9, 0.75))
        ft.box((s * 0.52, 0.17, -0.36), (0.38, 0.28, 0.34), "boot", bevel=0.12, segments=2)
        ft.box((s * 0.52, 0.17, -0.365), (0.4, 0.3, 0.36), "silver_dark", bevel=0.12, segments=2,
               clip=[((0, 0, -0.44), (0, 0, -1))])
        ft.box((s * 0.52, 0.04, -0.12), (0.42, 0.08, 0.86), "sole", bevel=0.03)


def model(fb):
    head(fb)
    torso(fb)
    arms(fb)
    legs(fb)
