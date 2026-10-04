"""Brann, forge smith. Hammer + Gauntlets. Slow, heavy tank."""

import math

import bmesh
from mathutils import Vector

from sky.common import rig_to_blender
from sky.rig import pivot, sides

NAME = "Brann"

COLORS = {
    "skin": "#eaa685",
    "skin_dark": "#c97d5f",
    "skin_red": "#de8268",
    "soot": "#4f474b",
    "beard": "#7c3519",
    "beard_dark": "#56230f",
    "eye_white": "#f6f1e7",
    "iris": "#3f6a86",
    "mouth": "#5e1f18",
    "bandana": "#c8302a",
    "bandana_dark": "#8e1e1a",
    "tunic": "#3b3c43",
    "tunic_dark": "#2a2a30",
    "apron": "#7d4b2a",
    "apron_dark": "#5a331b",
    "belt": "#4a2c18",
    "iron": "#6f757d",
    "iron_dark": "#474c53",
    "iron_light": "#a3abb3",
    "steel": "#aab3bb",
    "tan": "#b9925a",
    "tan_dark": "#94713f",
    "boot": "#5c3b26",
    "boot_dark": "#3e2718",
    "sole": "#2c211c",
    "wood": "#a8733f",
    "rag": "#9a9384",
    "ember": "#ff8a24",
    "ember_hot": "#ffd24a",
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


def scale_part(mb, about, k):
    """Uniformly scales everything already in a part builder about a rig-space point."""
    c = rig_to_blender(about)
    for v in mb.bm.verts:
        v.co = c + (v.co - c) * k


def ellipsoid_point(c, r, x, y, side=-1):
    cx, cy, cz = c
    rx, ry, rz = r
    t = 1 - ((x - cx) / rx) ** 2 - ((y - cy) / ry) ** 2
    z = cz + side * rz * math.sqrt(max(t, 0.0))
    n = Vector(((x - cx) / rx ** 2, (y - cy) / ry ** 2, (z - cz) / rz ** 2)).normalized()
    return Vector((x, y, z)), n


def decal(mb, c, r, x, y, size, color, side=-1, lift=0.0, segments=10):
    """Flattened blob sitting on an ellipsoid's surface (smudges, patches)."""
    p, n = ellipsoid_point(c, r, x, y, side)
    rot = Vector((0, 0, 1)).rotation_difference(n).to_matrix()
    mb.sphere(tuple(p + n * lift), size, color, rotation=rot, segments=segments, rings=6)


# Body ---------------------------------------------------------------------------

SKULL_C, SKULL_R = (0, 5.12, 0.02), (0.52, 0.58, 0.55)
BEARD_C, BEARD_R = (0, 4.58, -0.32), (0.44, 0.44, 0.4)
CHEST = [(0, 3.0, -0.02, 0.7, 0.5), (0, 3.4, -0.04, 0.8, 0.56), (0, 3.85, -0.04, 0.88, 0.58),
         (0, 4.2, -0.01, 0.9, 0.52), (0, 4.45, 0.02, 0.62, 0.38)]
HIPS = [(0, 2.3, 0, 0.7, 0.48), (0, 2.6, -0.01, 0.75, 0.51), (0, 2.9, -0.02, 0.72, 0.5)]
SKIRT = [(0, 2.25, -0.02, 0.84, 0.6), (0, 2.6, -0.02, 0.8, 0.56), (0, 2.95, -0.02, 0.745, 0.52),
         (0, 3.25, -0.02, 0.69, 0.5)]


def head(fb):
    h = fb["Head"]
    h.cylinder((0, 4.6, 0.04), 0.3, 0.5, "skin", segments=12)
    h.sphere(SKULL_C, SKULL_R, "skin", segments=18, rings=12)
    h.sphere((0, 4.92, -0.1), (0.45, 0.34, 0.43), "skin", segments=16, rings=10)
    for _, s in sides():
        h.sphere((s * 0.53, 5.08, 0.08), (0.08, 0.14, 0.1), "skin", segments=8, rings=6)
        h.sphere((s * 0.555, 5.08, 0.09), (0.03, 0.08, 0.05), "skin_dark", segments=6, rings=4)

    # eyes: kind, with heavy fierce brows
    for _, s in sides():
        h.sphere((s * 0.2, 5.1, -0.46), (0.105, 0.085, 0.07), "eye_white", segments=12, rings=8)
        h.sphere((s * 0.185, 5.095, -0.515), (0.062, 0.075, 0.03), "iris", segments=10, rings=6)
        h.sphere((s * 0.16, 5.125, -0.543), (0.022, 0.022, 0.01), "eye_white", segments=6, rings=4)
        h.box((s * 0.21, 5.235, -0.5), (0.27, 0.085, 0.08), "beard_dark", bevel=0.03, rotation=(0, 0, s * 12))
    # big ruddy nose, cheeks
    h.sphere((0, 5.07, -0.53), (0.065, 0.1, 0.06), "skin", segments=8, rings=6)
    h.sphere((0, 4.98, -0.6), (0.1, 0.09, 0.09), "skin_red", segments=10, rings=7)
    for _, s in sides():
        decal(h, SKULL_C, SKULL_R, s * 0.31, 4.98, (0.1, 0.06, 0.02), "skin_red", lift=-0.005)
    # soot smudges
    decal(h, SKULL_C, SKULL_R, -0.26, 5.3, (0.13, 0.05, 0.02), "soot", lift=-0.005)
    decal(h, SKULL_C, SKULL_R, 0.36, 5.04, (0.07, 0.045, 0.02), "soot", lift=-0.005)

    # beard: jaw shell up to the ears, a full mass under the chin, sideburns,
    # droopy moustache, a smile, and a thick braid with iron rings
    jaw_cut = [((0, 4.9, -0.5), (0, -1, 0.45)), ((0, 0, 0.2), (0, 0, -1))]
    h.sphere((0, 4.86, -0.1), (0.5, 0.38, 0.48), "beard", segments=16, rings=10, clip=jaw_cut)
    h.sphere(BEARD_C, BEARD_R, "beard", segments=16, rings=10, clip=[((0, 4.9, 0), (0, -1, 0))])
    for _, s in sides():
        h.limb((s * 0.49, 5.12, 0.07), (s * 0.45, 4.9, -0.02), 0.075, 0.1, "beard", segments=10)
        h.limb((s * 0.05, 4.9, -0.65), (s * 0.27, 4.78, -0.56), 0.085, 0.06, "beard_dark", segments=10)
    h.prism([(-0.09, 0.012), (-0.05, -0.012), (0, -0.02), (0.05, -0.012), (0.09, 0.012), (0.1, -0.005),
             (0.05, -0.045), (0, -0.055), (-0.05, -0.045), (-0.1, -0.005)], 0.03, "mouth", center=(0, 4.79, -0.655))
    # knotted red bandana over the shaved scalp
    edge = [((0, 5.36, -0.5), (0, 1.05, 0.28))]
    h.sphere((0, 5.12, 0.02), (0.545, 0.605, 0.575), "bandana", segments=18, rings=12, clip=edge)
    h.torus((0, 5.225, 0.025), 0.54, 0.045, "bandana_dark", rotation=(15, 0, 0), segments=20, sides=6,
            scale=(1.0, 1.03))
    h.sphere((0, 5.1, 0.6), (0.11, 0.1, 0.09), "bandana_dark", segments=10, rings=7)
    for _, s in sides():
        h.box((s * 0.09, 4.93, 0.7), (0.13, 0.36, 0.04), "bandana", bevel=0.015, rotation=(-28, 0, s * 18))

    # chunky toon proportions: a slightly oversized head
    scale_part(h, (0, 4.45, 0), 1.07)

    # braid hanging over the chest, iron rings
    braid = [(4.2, -0.64), (4.06, -0.7), (3.92, -0.735), (3.78, -0.76)]
    for i, (y, z) in enumerate(braid):
        h.sphere((0.02 if i % 2 else -0.02, y, z), (0.16 - i * 0.012, 0.1, 0.105), "beard" if i % 2 else "beard_dark",
                 rotation=(14, 0, 22 if i % 2 else -22), segments=10, rings=7)
    h.sphere((0, 3.66, -0.775), (0.085, 0.1, 0.075), "beard", segments=8, rings=6)
    for y, z in ((4.13, -0.675), (3.85, -0.75)):
        h.torus((0, y, z), 0.125, 0.045, "iron_light", rotation=(14, 0, 0), segments=12, sides=6)


def torso(fb):
    up = fb["UpperTorso"]
    up.loft(CHEST, "tunic", power=2.3, segments=18)
    up.sphere((0, 4.38, 0.06), (0.74, 0.24, 0.4), "tunic", segments=16, rings=8)

    # leather apron bib
    rows = []
    for y in (3.0, 3.25, 3.5, 3.75, 4.0, 4.22):
        w = 0.62 - (y - 3.0) * 0.17
        rows.append([(w * t, y, surface_z(CHEST, w * t, y, -1, offset=0.03)) for t in (-1, -0.66, -0.33, 0, 0.33, 0.66, 1)])
    panel(up, rows, "apron", 0.05)
    panel(up, [[(p[0], p[1] - dy, p[2] - 0.004) for p in rows[-1]] for dy in (0.09, 0.0)], "apron_dark", 0.06)
    # neck straps up into the traps
    for _, s in sides():
        up.limb((s * 0.42, 4.2, -0.5), (s * 0.4, 4.5, -0.12), 0.05, 0.05, "apron_dark", segments=8)
    # ember flame stitched on the bib
    up.prism([(0, 0.2), (0.07, 0.06), (0.11, -0.06), (0.06, -0.15), (-0.06, -0.15), (-0.11, -0.06), (-0.05, 0.04),
              (-0.02, -0.02)], 0.03, "ember", center=(0, 3.55, -0.6))
    up.prism([(0, 0.06), (0.05, -0.06), (0.02, -0.12), (-0.03, -0.12), (-0.05, -0.05)], 0.03, "ember_hot",
             center=(0, 3.53, -0.615))
    # crossed apron straps on the back
    for s in (-1, 1):
        strap(up, [(s * 0.42, 4.3), (-s * 0.62, 3.0)], 0.15, "apron_dark", CHEST, 1)

    low = fb["LowerTorso"]
    low.loft(HIPS, "tan", power=2.3, segments=16)
    # the tunic hangs to mid-thigh: a heavier body, shorter-looking legs
    low.loft(SKIRT, "tunic", power=2.3, segments=18, caps=(False, False))
    low.loft([(0, 2.24, -0.02, 0.855, 0.615), (0, 2.33, -0.02, 0.85, 0.61)], "tunic_dark", power=2.3, segments=18,
             caps=(False, False))
    # apron skirt
    rows = []
    for y in (3.04, 2.75, 2.45, 2.1, 1.78):
        w = 0.6 + (3.04 - y) * 0.11
        row = []
        for t in (-1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, 1):
            x = w * t
            z = surface_z(SKIRT, x, max(y, 2.25), -1, offset=0.045) - max(0.0, 2.25 - y) * 0.06
            row.append((x, y, z))
        rows.append(row)
    panel(low, rows, "apron", 0.05)
    hem = [[(p[0], p[1] + dy, p[2] - 0.004) for p in rows[-1]] for dy in (0.0, 0.14)]
    panel(low, hem, "apron_dark", 0.06)
    # front pocket with tool handles
    pocket = [[(p[0] * 0.42, y, p[2] - 0.03) for p in rows[3]] for y in (2.15, 2.48)]
    panel(low, pocket, "apron_dark", 0.05)
    low.cylinder((-0.1, 2.56, -0.7), 0.04, 0.24, "wood", rotation=(0, 0, 8), segments=8)
    low.cylinder((0.12, 2.54, -0.7), 0.035, 0.2, "iron", rotation=(0, 0, -10), segments=8)

    # tool belt: thick leather, iron buckle with an ember core, pouch, tongs
    low.loft([(0, 2.78, -0.02, 0.8, 0.6), (0, 3.02, -0.02, 0.8, 0.6)], "belt", power=2.5, segments=18)
    low.box((0, 2.9, -0.63), (0.28, 0.26, 0.06), "iron", bevel=0.03)
    low.box((0, 2.9, -0.66), (0.12, 0.1, 0.03), "ember", bevel=0.01)
    low.box((-0.86, 2.62, -0.1), (0.2, 0.38, 0.38), "apron_dark", bevel=0.06)
    low.box((-0.9, 2.78, -0.1), (0.16, 0.12, 0.4), "apron", bevel=0.03)
    low.box((0.8, 2.76, 0.24), (0.12, 0.24, 0.12), "belt", bevel=0.02)
    for s in (-1, 1):
        low.limb((0.86 + s * 0.04, 2.72, 0.26), (0.9 + s * 0.02, 2.12, 0.26), 0.035, 0.035, "iron_dark", segments=6)
        low.limb((0.9 + s * 0.02, 2.12, 0.26), (0.88 - s * 0.03, 1.9, 0.26), 0.035, 0.03, "iron_dark", segments=6)
    low.sphere((0.9, 2.12, 0.26), 0.05, "iron_light", segments=8, rings=5)
    rag = []
    for y, dz in ((3.0, 0.0), (2.75, 0.02), (2.5, 0.035), (2.2, 0.045)):
        rag.append([(x, y, surface_z(SKIRT, x, max(y, 2.25), 1, offset=0.035 + dz)) for x in (-0.62, -0.48, -0.32)])
    panel(low, rag, "rag", 0.04)


def arms(fb):
    for side, s in sides():
        ua = fb[f"{side}UpperArm"]
        el = pivot(f"{side}Elbow")
        ua.sphere((s * 1.07, 4.1, 0.0), (0.39, 0.38, 0.39), "skin", segments=16, rings=10)
        ua.limb((s * 1.1, 3.95, 0), (el[0], el[1] + 0.05, 0), 0.31, 0.25, "skin", segments=14)
        ua.sphere((s * 1.16, 3.68, -0.1), (0.27, 0.3, 0.25), "skin", segments=12, rings=8)
        ua.sphere((s * 1.16, 3.72, 0.08), (0.26, 0.3, 0.22), "skin", segments=12, rings=8)

        la = fb[f"{side}LowerArm"]
        wr = pivot(f"{side}Wrist")
        la.sphere(el, 0.26, "skin", segments=12, rings=8)
        la.loft([(s * 1.2, 3.38, 0, 0.26, 0.26), (s * 1.23, 3.12, -0.01, 0.37, 0.36), (s * 1.27, 2.85, 0, 0.37, 0.36),
                 (s * 1.3, 2.6, 0, 0.29, 0.29)], "skin", segments=14)
        # iron bracer with glowing vents
        la.loft([(s * 1.29, 2.62, 0, 0.36, 0.36), (s * 1.27, 2.82, 0, 0.39, 0.39), (s * 1.25, 3.02, 0, 0.41, 0.41)],
                "iron", segments=16)
        for y in (2.63, 3.0):
            la.loft([(s * (1.29 - (y - 2.62) * 0.1), y - 0.035, 0, 0.375 + (y - 2.62) * 0.1, 0.375 + (y - 2.62) * 0.1),
                     (s * (1.29 - (y - 2.62) * 0.1), y + 0.035, 0, 0.385 + (y - 2.62) * 0.1, 0.385 + (y - 2.62) * 0.1)],
                    "iron_dark", segments=16)
        for y in (2.76, 2.88):
            la.box((s * 1.66, y, 0), (0.04, 0.05, 0.24), "ember", bevel=0.01)
        for z in (-0.38, 0.38):
            la.sphere((s * 1.27, 2.82, z * 1.02), 0.035, "iron_light", segments=6, rings=4)

        hand = fb[f"{side}Hand"]
        hand.box((wr[0] + s * 0.05, 2.32, -0.02), (0.42, 0.48, 0.46), "skin", bevel=0.13, segments=2)
        hand.box((wr[0] + s * 0.06, 2.15, -0.12), (0.4, 0.18, 0.32), "skin", bevel=0.08)
        hand.limb((wr[0] - s * 0.13, 2.46, -0.17), (wr[0] - s * 0.15, 2.25, -0.27), 0.095, 0.08, "skin",
                  segments=8)
        hand.loft([(wr[0], 2.5, 0, 0.27, 0.27), (wr[0], 2.62, 0, 0.3, 0.3)], "tan_dark", segments=12)


def legs(fb):
    for side, s in sides():
        hip = pivot(f"{side}Hip")
        ul = fb[f"{side}UpperLeg"]
        ul.loft([(hip[0], 2.62, 0, 0.4, 0.42), (s * 0.54, 2.1, 0, 0.41, 0.42), (s * 0.53, 1.55, 0, 0.36, 0.38)],
                "tan", segments=14)

        ll = fb[f"{side}LowerLeg"]
        ll.loft([(s * 0.53, 1.58, 0, 0.36, 0.38), (s * 0.52, 1.3, 0, 0.37, 0.39), (s * 0.52, 1.1, 0, 0.33, 0.35)],
                "tan", segments=14)
        ll.box((s * 0.53, 1.45, -0.34), (0.3, 0.28, 0.1), "tan_dark", bevel=0.04, rotation=(-8, 0, s * 6))
        # heavy boot shaft with folded cuff and buckled straps
        ll.loft([(s * 0.52, 0.42, 0.02, 0.3, 0.33), (s * 0.52, 0.8, 0.0, 0.31, 0.34), (s * 0.52, 1.0, 0.0, 0.33, 0.36)],
                "boot", segments=14)
        ll.loft([(s * 0.52, 0.96, 0, 0.36, 0.39), (s * 0.52, 1.2, 0, 0.39, 0.42)], "boot_dark", segments=14)
        ll.loft([(s * 0.52, 0.62, 0, 0.32, 0.35), (s * 0.52, 0.72, 0, 0.325, 0.355)], "belt", segments=14)
        ll.box((s * 0.85, 0.67, -0.02), (0.05, 0.14, 0.14), "iron", bevel=0.015)

        ft = fb[f"{side}Foot"]
        ft.box((s * 0.52, 0.29, -0.1), (0.58, 0.5, 0.86), "boot", bevel=0.16, segments=2, taper=(0.92, 0.8))
        ft.box((s * 0.52, 0.22, -0.43), (0.56, 0.34, 0.4), "steel", bevel=0.14, segments=2)
        ft.box((s * 0.52, 0.06, -0.13), (0.62, 0.12, 1.0), "sole", bevel=0.04)
        ft.box((s * 0.52, 0.12, 0.28), (0.56, 0.2, 0.22), "sole", bevel=0.04)


def model(fb):
    head(fb)
    torso(fb)
    arms(fb)
    legs(fb)
