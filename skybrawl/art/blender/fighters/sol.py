"""Sol, sun knight. Sword + Hammer. Sturdy armored all-rounder."""

import math

import bmesh
from mathutils import Matrix, Vector

from sky.rig import pivot, sides

NAME = "Sol"

COLORS = {
    "skin": "#7a4a2e",
    "skin_dark": "#5c3420",
    "lip": "#4a1f19",
    "lip_low": "#8a4a3c",
    "hair": "#1d1718",
    "hair_hi": "#342a2b",
    "eye_white": "#f6f1e7",
    "iris": "#d98f1f",
    "pupil": "#3a1d08",
    "plate": "#eef0f4",
    "plate_shade": "#c5cad6",
    "gold": "#e6b23a",
    "gold_light": "#ffd96e",
    "sun_core": "#fff1b0",
    "crimson": "#a8192e",
    "cape": "#f3ead6",
    "under": "#3b3646",
    "leather": "#6b4226",
    "sole": "#2e2622",
}


# Helpers --------------------------------------------------------------------


def panel(mb, grid, color, thickness=0.05, smooth=True, clip=None):
    """Thick curved sheet through grid[row][col] points (rig space)."""
    tmp = bmesh.new()
    rows, cols = len(grid), len(grid[0])
    pts = [[Vector(p) for p in row] for row in grid]

    def normal(i, j):
        a = pts[i][min(j + 1, cols - 1)] - pts[i][max(j - 1, 0)]
        b = pts[min(i + 1, rows - 1)][j] - pts[max(i - 1, 0)][j]
        n = a.cross(b)
        return n.normalized() if n.length > 1e-9 else Vector((0, 0, 1))

    front = [[None] * cols for _ in range(rows)]
    back = [[None] * cols for _ in range(rows)]
    for i in range(rows):
        for j in range(cols):
            n = normal(i, j) * (thickness / 2)
            front[i][j] = tmp.verts.new(pts[i][j] + n)
            back[i][j] = tmp.verts.new(pts[i][j] - n)
    for i in range(rows - 1):
        for j in range(cols - 1):
            tmp.faces.new((front[i][j], front[i][j + 1], front[i + 1][j + 1], front[i + 1][j]))
            tmp.faces.new((back[i][j], back[i + 1][j], back[i + 1][j + 1], back[i][j + 1]))
    border = ([(0, j) for j in range(cols)] + [(i, cols - 1) for i in range(1, rows)]
              + [(rows - 1, j) for j in range(cols - 2, -1, -1)] + [(i, 0) for i in range(rows - 2, 0, -1)])
    for k in range(len(border)):
        i0, j0 = border[k]
        i1, j1 = border[(k + 1) % len(border)]
        tmp.faces.new((front[i0][j0], back[i0][j0], back[i1][j1], front[i1][j1]))
    bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
    mb._finish(tmp, color, (0, 0, 0), None, smooth, clip)


def section_at(sections, y):
    """Interpolated (zc, rx, rz) of a loft [(x, y, z, rx, rz), ...] at height y."""
    ss = sorted(sections, key=lambda s: s[1])
    if y <= ss[0][1]:
        return ss[0][2], ss[0][3], ss[0][4]
    for a, b in zip(ss, ss[1:]):
        if a[1] <= y <= b[1]:
            t = (y - a[1]) / (b[1] - a[1])
            return (a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, a[4] + (b[4] - a[4]) * t)
    return ss[-1][2], ss[-1][3], ss[-1][4]


def surface_z(sections, x, y, side=-1, power=2.3, offset=0.0):
    """z of a superellipse loft's surface at (x, y) on the front (-1) or back (+1)."""
    zc, rx, rz = section_at(sections, y)
    u = min(abs(x) / rx, 0.999)
    return zc + side * ((rz + offset) * (1 - u ** power) ** (1 / power))


def strap(mb, path, width, color, sections, side, thickness=0.04, lift=0.03, power=2.3, steps=10):
    """Flat strap lying on a loft surface along an (x, y) polyline."""
    pts = []
    for (x0, y0), (x1, y1) in zip(path, path[1:]):
        for k in range(steps):
            t = k / steps
            pts.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t))
    pts.append(path[-1])
    rows = []
    for i, (x, y) in enumerate(pts):
        xa, ya = pts[max(i - 1, 0)]
        xb, yb = pts[min(i + 1, len(pts) - 1)]
        tx, ty = xb - xa, yb - ya
        ln = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / ln * width / 2, tx / ln * width / 2
        row = []
        for sx, sy in ((x - nx, y - ny), (x + nx, y + ny)):
            row.append((sx, sy, surface_z(sections, sx, sy, side, power, lift)))
        rows.append(row)
    panel(mb, rows, color, thickness)


def spike(mb, base, direction, length, radius, color, segments=4):
    """Pointed ray (a pyramid) from `base` along `direction`."""
    d = Vector(direction).normalized()
    rot = Vector((0, 1, 0)).rotation_difference(d).to_matrix()
    mb.cone(tuple(Vector(base) + d * (length / 2)), radius, length, color, rotation=rot, segments=segments)


def star(points, r_tip, r_valley, phase=0.0):
    """2D outline of a sunburst star."""
    out = []
    for i in range(points * 2):
        a = math.pi / 2 + phase + math.pi * i / points
        r = r_tip if i % 2 == 0 else r_valley
        out.append((r * math.cos(a), r * math.sin(a)))
    return out


def sun(mb, center, size, depth=0.03, points=12, facing=(0, 0, -1)):
    """Golden sun emblem: rayed star, disc and bright core, facing `facing`."""
    rot = Vector((0, 0, -1)).rotation_difference(Vector(facing)).to_matrix()
    f = Vector(facing).normalized()
    c = Vector(center)
    mb.prism(star(points, size, size * 0.62), depth, "gold", center=tuple(c), rotation=rot)
    disc_rot = rot @ Matrix.Rotation(math.radians(90), 3, "X")
    mb.cylinder(tuple(c + f * depth * 0.6), size * 0.5, depth, "gold_light", rotation=disc_rot, segments=14)
    mb.cylinder(tuple(c + f * depth * 1.2), size * 0.3, depth, "sun_core", rotation=disc_rot, segments=10)


def fib_points(n):
    """Evenly spread unit vectors."""
    golden = math.pi * (3 - math.sqrt(5))
    for i in range(n):
        y = 1 - 2 * (i + 0.5) / n
        r = math.sqrt(1 - y * y)
        a = golden * i
        yield Vector((r * math.cos(a), y, r * math.sin(a)))


# Body ---------------------------------------------------------------------------

SKULL_C, SKULL_R = (0, 5.32, 0), (0.47, 0.57, 0.51)
HAIR_C, HAIR_R = (0, 5.36, 0.03), (0.495, 0.6, 0.54)
CHEST = [(0, 3.0, 0, 0.56, 0.4), (0, 3.4, -0.01, 0.6, 0.42), (0, 3.85, -0.03, 0.7, 0.47),
         (0, 4.2, -0.01, 0.72, 0.43), (0, 4.45, 0.02, 0.5, 0.32)]
HIPS = [(0, 2.3, 0, 0.58, 0.39), (0, 2.6, 0, 0.62, 0.41), (0, 2.95, 0, 0.57, 0.38), (0, 3.15, 0, 0.52, 0.36)]


def head(fb):
    h = fb["Head"]
    h.cylinder((0, 4.72, 0.02), 0.165, 0.6, "skin", segments=12)
    h.sphere(SKULL_C, SKULL_R, "skin", segments=18, rings=12)
    h.sphere((0, 5.08, -0.08), (0.345, 0.32, 0.4), "skin", segments=16, rings=10)
    h.sphere((0, 4.9, -0.29), (0.11, 0.09, 0.1), "skin", segments=10, rings=6)
    for _, s in sides():
        h.sphere((s * 0.47, 5.26, 0.04), (0.07, 0.12, 0.09), "skin", segments=8, rings=6)
        h.sphere((s * 0.27, 5.15, -0.3), (0.12, 0.08, 0.1), "skin", segments=8, rings=6)
        h.sphere((s * 0.49, 5.13, 0.05), 0.04, "gold", segments=8, rings=5)

    # warm amber eyes, lashes, calm arched brows
    for _, s in sides():
        h.sphere((s * 0.18, 5.26, -0.44), (0.1, 0.085, 0.065), "eye_white", segments=12, rings=8)
        h.sphere((s * 0.17, 5.255, -0.492), (0.062, 0.074, 0.03), "iris", segments=10, rings=6)
        h.sphere((s * 0.168, 5.255, -0.515), (0.032, 0.045, 0.012), "pupil", segments=8, rings=5)
        h.sphere((s * 0.15, 5.285, -0.526), (0.02, 0.02, 0.01), "eye_white", segments=6, rings=4)
        h.box((s * 0.19, 5.338, -0.49), (0.22, 0.03, 0.045), "hair", bevel=0.01, rotation=(0, 0, s * -6))
        h.box((s * 0.3, 5.345, -0.455), (0.06, 0.025, 0.04), "hair", bevel=0.008, rotation=(0, 0, s * 30))
        h.box((s * 0.19, 5.41, -0.475), (0.2, 0.035, 0.05), "hair", bevel=0.012, rotation=(0, 0, s * -5))
    h.sphere((0, 5.16, -0.5), (0.055, 0.075, 0.05), "skin", segments=8, rings=6)
    h.box((0, 5.11, -0.525), (0.07, 0.02, 0.02), "skin_dark", bevel=0.008)
    h.box((0, 5.012, -0.468), (0.16, 0.028, 0.03), "lip", bevel=0.012)
    h.sphere((0, 4.982, -0.462), (0.065, 0.03, 0.02), "lip_low", segments=10, rings=5)

    # short black curls
    h.sphere(HAIR_C, HAIR_R, "hair", segments=18, rings=12, clip=[((0, 5.55, -0.45), (0, 1, 0.62))])
    for i, p in enumerate(fib_points(44)):
        x, y, z = HAIR_C[0] + p.x * 0.45, HAIR_C[1] + 0.05 + p.y * 0.58, HAIR_C[2] + p.z * 0.49
        if (y - 5.62) + 0.62 * (z + 0.45) < 0 or y < 5.12:
            continue
        r = 0.12 + 0.02 * (i % 3)
        h.sphere((x, y, z), r, "hair_hi" if i % 4 == 0 else "hair", segments=7, rings=5)

    # gold circlet with a small sun on the brow
    h.torus((0, 5.6, 0.0), 0.5, 0.035, "gold", rotation=(-12, 0, 0), segments=20, sides=6, scale=(1.0, 1.08))
    sun(h, (0, 5.49, -0.545), 0.13, depth=0.025, points=8)


def torso(fb):
    up = fb["UpperTorso"]
    up.loft(CHEST, "plate", power=2.3, segments=18)
    # abdominal lames
    for y in (3.02, 3.18):
        up.loft([(0, y, -0.005, 0.575, 0.41), (0, y + 0.16, -0.008, 0.6, 0.425)], "plate_shade", power=2.3,
                segments=18)
        up.loft([(0, y - 0.02, -0.005, 0.58, 0.415), (0, y + 0.02, -0.005, 0.585, 0.418)], "gold", power=2.3,
                segments=18)
    up.loft([(0, 3.33, -0.01, 0.605, 0.43), (0, 3.38, -0.01, 0.61, 0.432)], "gold", power=2.3, segments=18)
    # plackart: a shaded pointed plate over the belly, gold edged, and a keel ridge
    rows = []
    for y, w in ((3.36, 0.5), (3.52, 0.36), (3.68, 0.2), (3.84, 0.03)):
        rows.append([(w * t, y, surface_z(CHEST, w * t, y, -1, offset=0.012)) for t in (-1, -0.5, 0, 0.5, 1)])
    panel(up, rows, "plate_shade", 0.03)
    for s in (-1, 1):
        strap(up, [(s * 0.52, 3.36), (0, 3.88)], 0.055, "gold", CHEST, -1, thickness=0.03, lift=0.026, steps=6)
    strap(up, [(0, 3.88), (0, 4.25)], 0.055, "gold", CHEST, -1, thickness=0.03, lift=0.014, steps=6)
    # gorget
    up.loft([(0, 4.32, 0.02, 0.42, 0.33), (0, 4.5, 0.02, 0.33, 0.27), (0, 4.62, 0.02, 0.27, 0.23)], "plate",
            segments=16, power=2.2)
    up.torus((0, 4.62, 0.02), 0.26, 0.03, "gold", segments=16, sides=6, scale=(1.0, 0.88))

    # short white cape: gathered at the shoulders, flaring into folds, gold
    # trim, a sun on the back
    def cape_row(y, rx, rz, wave, drop=0.0, a0=-76, a1=76, n=13, lift=0.0):
        row = []
        for k in range(n):
            a = math.radians(a0 + (a1 - a0) * k / (n - 1))
            r = rz + wave * math.cos(a * 5) + lift
            row.append((rx * math.sin(a), y - drop * math.cos(a) ** 2, 0.02 + r * math.cos(a)))
        return row

    shape = ((4.52, 0.4, 0.3, 0.0, 0.0), (4.32, 0.6, 0.43, 0.0, 0.0), (3.9, 0.7, 0.53, 0.015, 0.0),
             (3.4, 0.76, 0.62, 0.03, 0.03), (3.0, 0.8, 0.7, 0.045, 0.08), (2.86, 0.8, 0.74, 0.05, 0.12))
    panel(up, [cape_row(*r) for r in shape], "cape", 0.05)
    hem = [cape_row(2.86 + dy, 0.8, 0.74, 0.05, 0.12, lift=0.004) for dy in (0.0, 0.12)]
    panel(up, hem, "gold", 0.07)
    for a0, a1 in ((-76, -71), (71, 76)):
        panel(up, [cape_row(*r, a0=a0, a1=a1, n=2, lift=0.004) for r in shape], "gold", 0.065)
    sun(up, (0, 3.62, 0.672), 0.26, depth=0.03, points=12, facing=(0, 0, 1))
    up.torus((0, 4.36, 0.02), 0.44, 0.04, "gold", segments=16, sides=4, scale=(1.0, 0.78))
    for _, s in sides():
        sun(up, (s * 0.5, 4.36, -0.3), 0.09, depth=0.025, points=8, facing=(s * 0.4, 0.2, -1))


def arms(fb):
    for side, s in sides():
        ua = fb[f"{side}UpperArm"]
        el = pivot(f"{side}Elbow")
        ua.loft([(s * 1.08, 3.95, 0, 0.25, 0.25), (s * 1.15, 3.6, 0, 0.235, 0.235), (el[0], el[1] + 0.02, 0, 0.215, 0.215)],
                "plate_shade", segments=14)
        ua.loft([(s * 1.16, 3.56, 0, 0.235, 0.235), (s * 1.17, 3.62, 0, 0.24, 0.24)], "gold", segments=14)
        # sun-ray pauldron: layered domes and a halo of golden rays
        ua.sphere((s * 1.12, 4.04, 0), (0.4, 0.24, 0.42), "plate", segments=16, rings=10,
                  clip=[((0, 3.86, 0), (0, 1, 0))])
        ua.torus((s * 1.12, 3.875, 0), 0.38, 0.035, "gold", segments=16, sides=4, scale=(1.0, 1.05))
        ua.sphere((s * 1.1, 4.14, 0), (0.37, 0.26, 0.39), "plate", segments=16, rings=10,
                  clip=[((0, 3.97, 0), (0, 1, 0))])
        ua.torus((s * 1.1, 3.985, 0), 0.355, 0.035, "gold", segments=16, sides=4, scale=(1.0, 1.05))
        # the ray fan faces outward and a little forward, so it reads from the
        # side (gameplay) and still fans out in front views
        tilt = math.radians(28)
        n = Vector((s * math.cos(tilt), 0, -math.sin(tilt)))
        w = Vector((s * math.sin(tilt), 0, math.cos(tilt)))
        c = Vector((s * 1.2, 4.12, -0.02))
        for i, deg in enumerate(range(-110, 111, 22)):
            a = math.radians(deg)
            d = (Vector((0, math.cos(a), 0)) + w * math.sin(a) + n * 0.5).normalized()
            long_ray = i % 2 == 0
            spike(ua, c + d * 0.24, d, 0.46 if long_ray else 0.3, 0.09 if long_ray else 0.07,
                  "gold" if long_ray else "gold_light")
        sun(ua, tuple(c + n * 0.3 + Vector((0, -0.02, 0))), 0.13, depth=0.03, points=8, facing=tuple(n))

        la = fb[f"{side}LowerArm"]
        wr = pivot(f"{side}Wrist")
        la.sphere(el, 0.21, "under", segments=12, rings=8)
        la.sphere((el[0] + s * 0.03, el[1] - 0.02, 0.07), (0.2, 0.2, 0.17), "plate", segments=12, rings=8)
        la.loft([(s * 1.21, 3.25, 0, 0.215, 0.215), (s * 1.25, 2.95, 0, 0.235, 0.235), (s * 1.29, 2.72, 0, 0.24, 0.24)],
                "plate", segments=14)
        la.loft([(s * 1.29, 2.56, 0, 0.3, 0.3), (s * 1.28, 2.72, 0, 0.27, 0.27), (s * 1.28, 2.8, 0, 0.255, 0.255)],
                "gold", segments=14)
        la.loft([(s * 1.21, 3.22, 0, 0.225, 0.225), (s * 1.215, 3.27, 0, 0.23, 0.23)], "gold", segments=14)

        hand = fb[f"{side}Hand"]
        hand.box((wr[0] + s * 0.04, 2.33, -0.02), (0.33, 0.44, 0.38), "plate", bevel=0.11, segments=2)
        hand.box((wr[0] + s * 0.05, 2.17, -0.1), (0.31, 0.16, 0.27), "plate_shade", bevel=0.07)
        hand.box((wr[0] + s * 0.05, 2.3, -0.12), (0.32, 0.07, 0.24), "gold", bevel=0.02)
        hand.limb((wr[0] - s * 0.1, 2.46, -0.15), (wr[0] - s * 0.13, 2.27, -0.23), 0.075, 0.065, "plate",
                  segments=8)


def lower_torso(fb):
    low = fb["LowerTorso"]
    low.loft(HIPS, "under", power=2.3, segments=16)
    # sword belt
    low.loft([(0, 2.9, 0, 0.6, 0.42), (0, 3.04, 0, 0.59, 0.41)], "leather", power=2.4, segments=18)
    low.box((0, 2.97, -0.43), (0.18, 0.15, 0.05), "gold", bevel=0.02)
    # hip plates (tassets)
    # hip plates (tassets) wrapping the front and outside of each thigh
    def tasset_row(s, y, cx, r, lift=0.0):
        return [(s * (cx + (r + lift) * math.sin(math.radians(a))), y, -(r + lift) * math.cos(math.radians(a)))
                for a in range(-40, 111, 25)]

    for _, s in sides():
        for (y0, c0, r0), (y1, c1, r1) in (((2.95, 0.38, 0.3), (2.56, 0.5, 0.42)),
                                          ((2.62, 0.48, 0.4), (2.2, 0.52, 0.46))):
            rows = [tasset_row(s, y0 + (y1 - y0) * t, c0 + (c1 - c0) * t, r0 + (r1 - r0) * t) for t in (0, 0.5, 1)]
            panel(low, rows, "plate", 0.045)
            rim = [tasset_row(s, y1 + dy, c1, r1, lift=0.006) for dy in (0.0, 0.06)]
            panel(low, rim, "gold", 0.055)
    # crimson tabard, front and back, with a golden sun
    for side in (-1, 1):
        rows = []
        for y in (2.92, 2.6, 2.25, 1.95, 1.78):
            w = 0.34 + (2.92 - y) * 0.05
            hang = min(1.0, (2.92 - y) / 0.5)
            row = []
            for t in (-1, -0.5, 0, 0.5, 1):
                x = w * t
                body = surface_z(HIPS, x, max(y, 2.3), side, offset=0.03)
                drape = side * (0.47 - 0.05 * t * t)
                row.append((x, y, body + (drape - body) * hang))
            rows.append(row)
        panel(low, rows, "crimson", 0.045)
        hem = [[(p[0], p[1] + dy, p[2]) for p in rows[-1]] for dy in (0.0, 0.09)]
        panel(low, hem, "gold", 0.06)
        if side < 0:
            sun(low, (0, 2.32, -0.5), 0.2, depth=0.03, points=12)


def legs(fb):
    for side, s in sides():
        hip = pivot(f"{side}Hip")
        ul = fb[f"{side}UpperLeg"]
        ul.loft([(hip[0], 2.62, 0, 0.31, 0.33), (s * 0.53, 2.1, 0, 0.32, 0.34), (s * 0.52, 1.55, 0, 0.27, 0.29)],
                "under", segments=14)
        # cuisse over the front of the thigh
        ul.loft([(s * 0.53, 2.45, 0, 0.34, 0.36), (s * 0.53, 2.05, 0, 0.345, 0.365), (s * 0.52, 1.7, 0, 0.3, 0.32)],
                "plate", segments=14, clip=[((0, 0, 0.06), (0, 0, -1))])

        ll = fb[f"{side}LowerLeg"]
        kn = pivot(f"{side}Knee")
        ll.sphere((kn[0], kn[1] - 0.02, -0.12), (0.24, 0.22, 0.2), "plate", segments=12, rings=8)
        ll.sphere((kn[0] + s * 0.2, kn[1] - 0.02, -0.06), (0.06, 0.13, 0.12), "gold", segments=8, rings=6)
        ll.loft([(s * 0.52, 0.45, 0.02, 0.22, 0.25), (s * 0.52, 0.9, 0.0, 0.25, 0.28), (s * 0.52, 1.35, 0.0, 0.27, 0.29)],
                "plate", segments=14)
        ll.loft([(s * 0.52, 1.33, 0, 0.28, 0.3), (s * 0.52, 1.39, 0, 0.285, 0.305)], "gold", segments=14)
        ll.loft([(s * 0.52, 0.48, 0.02, 0.235, 0.265), (s * 0.52, 0.55, 0.02, 0.24, 0.27)], "gold", segments=14)
        ll.box((s * 0.52, 0.92, -0.27), (0.05, 0.7, 0.04), "gold", bevel=0.015)

        ft = fb[f"{side}Foot"]
        ft.box((s * 0.52, 0.26, -0.08), (0.42, 0.44, 0.76), "plate", bevel=0.14, segments=2, taper=(0.9, 0.75))
        ft.box((s * 0.52, 0.17, -0.4), (0.38, 0.26, 0.3), "plate", bevel=0.1, segments=2)
        ft.box((s * 0.52, 0.27, -0.28), (0.4, 0.04, 0.12), "gold", bevel=0.015, rotation=(-30, 0, 0))
        ft.box((s * 0.52, 0.05, -0.12), (0.45, 0.1, 0.86), "sole", bevel=0.04)


def model(fb):
    head(fb)
    torso(fb)
    arms(fb)
    lower_torso(fb)
    legs(fb)
