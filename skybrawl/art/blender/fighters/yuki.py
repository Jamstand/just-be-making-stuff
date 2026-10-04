"""Yuki, frost ranger. Spear + Bow. Quick and precise."""

import math

import bmesh
from mathutils import Vector

from sky.rig import pivot, sides

NAME = "Yuki"

COLORS = {
    "skin": "#f4d6c4",
    "skin_dark": "#dfae98",
    "blush": "#f1a2a0",
    "lips": "#c8707a",
    "eye_white": "#f7f8fb",
    "iris": "#4cb8e6",
    "pupil": "#183456",
    "lash": "#2a3550",
    "brow": "#8d9ab2",
    "hair": "#e8edf5",
    "hair_dark": "#b8c4d8",
    "tunic": "#a9d3ef",
    "tunic_dark": "#7fb0d6",
    "navy": "#24315e",
    "navy_dark": "#172041",
    "navy_light": "#3a4b85",
    "sash": "#3d78c2",
    "snow": "#ffffff",
    "cape": "#eef2f8",
    "cape_dark": "#ccd6e4",
    "fur": "#fbf8f1",
    "fur_dark": "#dcd5c8",
    "crystal": "#86eaff",
    "crystal_glow": "#e2fdff",
    "silver": "#c3cfdd",
    "leather": "#7a5236",
    "leather_dark": "#553722",
    "shaft": "#d9c08f",
    "fletch": "#5fa8dd",
    "boot": "#d6e0ec",
    "boot_dark": "#aebdd0",
    "sole": "#3a4562",
}


# Extra primitives -------------------------------------------------------------


def _catmull(points, values, samples):
    """Catmull-Rom curve through `points`; `values` (radii) are interpolated
    linearly alongside. Returns [(Vector, value), ...]."""
    pts = [Vector(p) for p in points]
    out = []
    for i in range(len(pts) - 1):
        p0 = pts[i - 1] if i > 0 else pts[i] * 2 - pts[i + 1]
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[i + 2] if i + 2 < len(pts) else p2 * 2 - p1
        v1, v2 = values[i], values[i + 1]
        for k in range(samples):
            t = k / samples
            t2, t3 = t * t, t * t * t
            p = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                       + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
            out.append((p, tuple(a + (b - a) * t for a, b in zip(v1, v2))))
    out.append((pts[-1], values[-1]))
    return out


def sweep(mb, points, radii, color, samples=3, segments=12, hint=None, caps=True, smooth=True, clip=None):
    """Tube along a smooth curve through `points`. `radii` per point is r or
    (ra, rb); rb lies along `hint` (a vector or a function of the point), so a
    flat strand (ra > rb) lies flat against the surface the hint points out of.
    A zero radius makes a pointed tip."""
    radii = [(r, r) if isinstance(r, (int, float)) else tuple(r) for r in radii]
    path = _catmull(points, radii, samples)
    tmp = bmesh.new()
    rings = []
    n = len(path)
    prev_b = None
    for i, (p, (ra, rb)) in enumerate(path):
        t = (path[min(i + 1, n - 1)][0] - path[max(i - 1, 0)][0]).normalized()
        if hint is not None:
            h = Vector(hint(p) if callable(hint) else hint)
        elif prev_b is not None:
            h = prev_b
        else:
            h = t.orthogonal()
        b = h - t * h.dot(t)
        if b.length < 1e-6:
            b = t.orthogonal()
        b.normalize()
        prev_b = b
        nn = b.cross(t).normalized()
        if ra < 1e-4 and rb < 1e-4:
            rings.append([tmp.verts.new(p)])
            continue
        ring = []
        for k in range(segments):
            a = 2 * math.pi * k / segments
            ring.append(tmp.verts.new(p + nn * (ra * math.cos(a)) + b * (rb * math.sin(a))))
        rings.append(ring)
    for r0, r1 in zip(rings, rings[1:]):
        if len(r0) == 1 and len(r1) == 1:
            continue
        if len(r0) == 1 or len(r1) == 1:
            tip, ring = (r0[0], r1) if len(r0) == 1 else (r1[0], r0)
            for k in range(len(ring)):
                tmp.faces.new((tip, ring[k], ring[(k + 1) % len(ring)]))
            continue
        for k in range(segments):
            j = (k + 1) % segments
            tmp.faces.new((r0[k], r0[j], r1[j], r1[k]))
    if caps:
        for ring in (rings[0], rings[-1]):
            if len(ring) > 2:
                tmp.faces.new(ring)
    mb._finish(tmp, color, (0, 0, 0), None, smooth, clip)


def shell(mb, sections, color, a0, a1, thick, segments=12, hem=None, smooth=True, fade=True, folds=None):
    """A thick curved panel: a slice (angles a0..a1 degrees, 0 = +X, 90 = +Z,
    i.e. behind) of an elliptical tube through sections [(cx, y, cz, rx, rz)].
    `hem(f)` (f = 0..1 along the arc) offsets the bottom edge's height; the
    offset fades out toward the top section (unless `fade` is False).
    `folds` = (count, depth) ripples the panel into cloth folds that deepen
    toward the bottom."""
    tmp = bmesh.new()
    outer, inner = [], []
    last = len(sections) - 1
    y0, y1 = sections[0][1], sections[-1][1]
    for si, (cx, y, cz, rx, rz) in enumerate(sections):
        o, n = [], []
        w = (y0 - y) / (y0 - y1) if (fade and y0 != y1) else 1.0
        for k in range(segments + 1):
            f = k / segments
            a = math.radians(a0 + (a1 - a0) * f)
            yy = y + (hem(f) * w if hem else 0.0)
            c, s_ = math.cos(a), math.sin(a)
            m = 1.0
            if folds:
                m += folds[1] * ((y0 - y) / (y0 - y1)) * math.cos(2 * math.pi * folds[0] * f)
            o.append(tmp.verts.new((cx + rx * m * c, yy, cz + rz * m * s_)))
            n.append(tmp.verts.new((cx + (rx * m - thick) * c, yy, cz + (rz * m - thick) * s_)))
        outer.append(o)
        inner.append(n)
    for i in range(last):
        for k in range(segments):
            tmp.faces.new((outer[i][k], outer[i][k + 1], outer[i + 1][k + 1], outer[i + 1][k]))
            tmp.faces.new((inner[i][k], inner[i + 1][k], inner[i + 1][k + 1], inner[i][k + 1]))
        for k in (0, segments):
            tmp.faces.new((outer[i][k], outer[i + 1][k], inner[i + 1][k], inner[i][k]))
    for i in (0, last):
        for k in range(segments):
            tmp.faces.new((outer[i][k], inner[i][k], inner[i][k + 1], outer[i][k + 1]))
    bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
    mb._finish(tmp, color, (0, 0, 0), None, smooth)


def fur_ring(mb, center, radius, tube, color, bumps=8, per=4, sides_=6, rotation=None, scale=(1, 1),
             lumpy=0.3, clip=None):
    """Torus whose tube swells into `bumps` cloud-like tufts: a fur trim."""
    tmp = bmesh.new()
    seg = bumps * per
    grid = []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        tb = tube * (1 - lumpy + lumpy * abs(math.cos(bumps * a / 2 + math.pi / 2)))
        ring = []
        for j in range(sides_):
            b = 2 * math.pi * j / sides_
            r = radius + tb * math.cos(b)
            ring.append(tmp.verts.new((r * math.cos(a) * scale[0], tb * math.sin(b), r * math.sin(a) * scale[1])))
        grid.append(ring)
    for i in range(seg):
        a, b = grid[i], grid[(i + 1) % seg]
        for j in range(sides_):
            k = (j + 1) % sides_
            tmp.faces.new((a[j], b[j], b[k], a[k]))
    mb._finish(tmp, color, center, rotation, True, clip)


def snowflake(mb, center, size, color, depth=0.025, rotation=None):
    """Six-armed star (a little snowflake motif)."""
    pts = []
    for i in range(12):
        a = math.pi / 2 + math.pi * i / 6
        r = size if i % 2 == 0 else size * 0.38
        pts.append((r * math.cos(a), r * math.sin(a)))
    mb.prism(pts, depth, color, center=center, rotation=rotation)


def _radial(cx, cy, cz):
    def h(p):
        return Vector((p.x - cx, p.y - cy, p.z - cz)).normalized()
    return h


# Head -----------------------------------------------------------------------------

CAP = ((0, 5.2, 0.02), (0.515, 0.61, 0.56))  # hair cap ellipsoid (center, radii)


def surf(x, y, out=0.03, back=False):
    """Point on the hair cap at (x, y), front (or back) side, pushed `out`."""
    (cx, cy, cz), (rx, ry, rz) = CAP
    u = max(0.0, 1 - (x / rx) ** 2 - ((y - cy) / ry) ** 2)
    z = cz + (1 if back else -1) * rz * math.sqrt(u)
    n = Vector(((x - cx) / rx ** 2, (y - cy) / ry ** 2, (z - cz) / rz ** 2)).normalized()
    return tuple(Vector((x, y, z)) + n * out)


def head(fb):
    h = fb["Head"]
    # neck, skull, soft jaw, ears
    h.cylinder((0, 4.55, 0.02), 0.145, 0.45, "skin", segments=10)
    h.sphere((0, 5.18, 0.0), (0.49, 0.585, 0.53), "skin", segments=18, rings=12)
    h.sphere((0, 4.96, -0.08), (0.37, 0.32, 0.4), "skin", segments=16, rings=10)
    for _, s in sides():
        h.sphere((s * 0.485, 5.08, 0.06), (0.06, 0.11, 0.08), "skin", segments=8, rings=6)

    # face: big calm ice-blue eyes, lash lines, soft brows, rosy cheeks
    for _, s in sides():
        h.sphere((s * 0.2, 5.08, -0.44), (0.12, 0.125, 0.06), "eye_white", segments=14, rings=8)
        h.sphere((s * 0.19, 5.065, -0.49), (0.082, 0.105, 0.025), "iris", segments=14, rings=8)
        h.sphere((s * 0.187, 5.06, -0.512), (0.044, 0.058, 0.01), "pupil", segments=10, rings=6)
        h.sphere((s * 0.158, 5.105, -0.52), (0.025, 0.025, 0.008), "eye_white", segments=6, rings=4)
        # calm, slightly lowered lids
        h.sphere((s * 0.2, 5.08, -0.436), (0.128, 0.132, 0.068), "skin", segments=14, rings=8,
                 clip=[((0, 5.168, 0), (0, 1, 0))])
        sweep(h, [(s * 0.075, 5.165, -0.49), (s * 0.2, 5.18, -0.505), (s * 0.31, 5.16, -0.455),
                  (s * 0.35, 5.13, -0.42)],
              [(0.022, 0.018), (0.03, 0.02), (0.028, 0.02), (0.0, 0.0)], "lash", samples=2, segments=5,
              hint=(0, 0, -1))
        sweep(h, [(s * 0.1, 5.3, -0.49), (s * 0.2, 5.33, -0.485), (s * 0.29, 5.31, -0.45)],
              [(0.022, 0.015), (0.024, 0.016), (0.0, 0.0)], "brow", samples=2, segments=5, hint=(0, 0, -1))
        h.sphere((s * 0.3, 4.94, -0.38), (0.085, 0.05, 0.035), "blush", rotation=(0, -s * 38, 0),
                 segments=10, rings=6)
    h.sphere((0, 4.975, -0.505), (0.022, 0.034, 0.03), "skin", segments=8, rings=6)
    # small calm smile
    sweep(h, [(-0.075, 4.865, -0.462), (0, 4.848, -0.478), (0.075, 4.865, -0.462)],
          [(0.016, 0.012)] * 3, "lips", samples=3, segments=6, hint=(0, 0, -1))

    # hair: pulled back from the face, side-swept fringe, face-framing locks
    hairline = [((0, 5.36, -0.5), (0, 1.0, 0.45))]
    h.sphere(CAP[0], CAP[1], "hair", segments=18, rings=12, clip=hairline)
    h.sphere((0, 5.12, 0.06), (0.505, 0.6, 0.53), "hair", segments=16, rings=10,
             clip=[((0, 4.95, 0.12), (0, 0.55, 1)), ((0, 4.72, 0), (0, 1, 0))])
    radial = _radial(0, 5.15, 0.0)
    # fringe: separate pointed locks swept toward her right, darker locks behind
    for pts, rad, col in (
        ([(-0.1, 5.8), (0.1, 5.55), (0.26, 5.36), (0.33, 5.24)], [0.15, 0.15, 0.1, 0], "hair"),
        ([(0.08, 5.79), (0.28, 5.58), (0.41, 5.4), (0.46, 5.26)], [0.13, 0.13, 0.08, 0], "hair"),
        ([(-0.2, 5.78), (-0.12, 5.55), (-0.04, 5.38), (0.0, 5.3)], [0.12, 0.12, 0.08, 0], "hair"),
        ([(-0.18, 5.76), (-0.3, 5.56), (-0.38, 5.4)], [0.12, 0.09, 0], "hair"),
        ([(0.0, 5.72), (0.15, 5.5), (0.2, 5.36)], [0.11, 0.08, 0], "hair_dark"),
        ([(-0.3, 5.66), (-0.21, 5.46), (-0.18, 5.38)], [0.1, 0.07, 0], "hair_dark"),
    ):
        out = 0.03 if col == "hair_dark" else 0.06
        sweep(h, [surf(x, y, out if i else 0.0) for i, (x, y) in enumerate(pts)],
              [(r, r * 0.42) for r in rad], col, hint=radial, samples=2, segments=7)
    for _, s in sides():
        sweep(h, [surf(s * 0.36, 5.5, 0.03), (s * 0.48, 5.18, -0.3), (s * 0.47, 4.88, -0.3),
                  (s * 0.42, 4.64, -0.28)],
              [(0.1, 0.06), (0.1, 0.06), (0.07, 0.045), (0, 0)], "hair", hint=radial, samples=2, segments=8)

    # the signature high ponytail with a navy ribbon
    tie = Vector((0, 5.74, 0.34))
    sweep(h, [(0, 5.6, 0.2), (0, 5.8, 0.42), (0, 5.86, 0.66), (0, 5.68, 0.9), (0, 5.3, 1.0),
              (0, 4.85, 0.96), (0, 4.4, 0.88), (0, 4.05, 0.82), (0, 3.85, 0.84)],
          [0.13, 0.15, 0.2, 0.235, 0.24, 0.21, 0.17, 0.1, 0.0], "hair", samples=2, segments=14)
    # a darker under-lock so the tail reads as two strands
    sweep(h, [(0.04, 5.75, 0.6), (0.06, 5.5, 0.87), (0.07, 5.0, 0.92), (0.1, 4.5, 0.8), (0.14, 4.15, 0.74)],
          [0.1, 0.14, 0.14, 0.1, 0.0], "hair_dark", samples=2, segments=8)
    h.torus(tie + Vector((0, 0.04, 0.05)), 0.14, 0.05, "navy", rotation=(53, 0, 0), segments=14, sides=6)
    for _, s in sides():
        h.sphere((s * 0.19, 5.86, 0.42), (0.15, 0.085, 0.055), "navy", rotation=(30, 0, s * -25),
                 segments=10, rings=6)
        sweep(h, [(s * 0.05, 5.78, 0.46), (s * 0.12, 5.6, 0.56), (s * 0.18, 5.42, 0.6)],
              [(0.06, 0.02), (0.06, 0.02), (0.05, 0.02)], "navy_light", hint=(0, 0, 1), segments=6)
    h.sphere((0, 5.82, 0.43), (0.07, 0.07, 0.06), "navy_dark", segments=8, rings=6)


# Torso ----------------------------------------------------------------------------


def torso(fb):
    up = fb["UpperTorso"]
    # quilted pale-blue tunic: puffy horizontal channels with darker seams
    up.loft([(0, 3.0, 0, 0.44, 0.3), (0, 3.3, 0, 0.45, 0.31), (0, 3.6, 0, 0.48, 0.33), (0, 3.9, 0, 0.53, 0.35),
             (0, 4.15, 0, 0.56, 0.34), (0, 4.32, 0, 0.52, 0.3), (0, 4.46, 0, 0.36, 0.25)],
            "tunic", power=2.3, segments=16)
    up.sphere((0, 3.86, -0.1), (0.44, 0.24, 0.27), "tunic", segments=14, rings=8)
    for y, rx, rz in ((3.38, 0.46, 0.315), (3.68, 0.5, 0.34)):
        up.loft([(0, y - 0.02, 0, rx + 0.005, rz + 0.005), (0, y + 0.02, 0, rx + 0.005, rz + 0.005)],
                "tunic_dark", power=2.3, segments=16)
    # navy placket down the front
    up.box((0, 3.45, -0.325), (0.12, 0.85, 0.04), "navy", bevel=0.015, rotation=(-4, 0, 0))

    # fur collar around the shoulders, short white cape behind, hood folded down
    fur_ring(up, (0, 4.43, 0.05), 0.5, 0.17, "fur", bumps=9, scale=(1.18, 0.86), rotation=(-6, 0, 0))
    for _, s in sides():
        up.sphere((s * 0.66, 4.36, 0.02), (0.22, 0.17, 0.24), "fur", segments=12, rings=7)
    # (short at the sides, dipping to a rounded point at the back)
    cape = [(0, 4.48, 0.04, 0.6, 0.4), (0, 4.1, 0.05, 0.74, 0.45), (0, 3.7, 0.06, 0.83, 0.49),
            (0, 3.3, 0.08, 0.89, 0.53), (0, 2.95, 0.1, 0.93, 0.56)]
    cape_hem = lambda f: 0.8 * abs(2 * f - 1) ** 1.4  # noqa: E731
    shell(up, cape, "cape", 12, 168, 0.07, segments=16, hem=cape_hem, folds=(4, 0.045))
    # fur lining peeking out along the hem
    hem_pts = []
    for i in range(17):
        f = i / 16
        a = math.radians(12 + 156 * f)
        m = 1 + 0.045 * math.cos(2 * math.pi * 4 * f)
        hem_pts.append((0.9 * m * math.cos(a), 2.95 + cape_hem(f), 0.1 + 0.53 * m * math.sin(a)))
    sweep(up, hem_pts, [0.055] * 17, "fur", samples=2, segments=6)
    up.sphere((0, 4.3, 0.5), (0.36, 0.22, 0.15), "cape", segments=14, rings=8)
    up.sphere((0, 4.24, 0.57), (0.26, 0.12, 0.09), "cape_dark", segments=12, rings=6)

    # ice-crystal pendant
    up.sphere((0, 4.2, -0.36), (0.05, 0.04, 0.04), "silver", segments=8, rings=5)
    sweep(up, [(0, 4.18, -0.4), (0, 4.08, -0.41), (0, 3.92, -0.4)], [(0.075, 0.05), (0.075, 0.05), 0],
          "crystal", samples=1, segments=6, hint=(0, 0, 1), smooth=False)
    up.sphere((-0.015, 4.07, -0.445), (0.025, 0.04, 0.012), "crystal_glow", segments=6, rings=4)

    # quiver strap across the chest, quiver on the back (over the cape)
    strap_hint = _radial(0, 3.7, 0.0)
    sweep(up, [(0.62, 4.45, 0.15), (0.55, 4.38, -0.14), (0.32, 4.12, -0.37), (0.0, 3.78, -0.41),
               (-0.3, 3.45, -0.37), (-0.45, 3.15, -0.25)],
          [(0.07, 0.025)] * 6, "leather", hint=strap_hint, segments=8)
    sweep(up, [(0.62, 4.45, 0.15), (0.55, 4.42, 0.4), (0.42, 4.32, 0.55)],
          [(0.07, 0.025)] * 3, "leather", hint=strap_hint, segments=8)
    qa, qb = Vector((0.06, 3.3, 0.8)), Vector((0.45, 4.42, 0.64))
    up.limb(qa, qb, 0.125, 0.15, "leather", segments=12)
    axis = (qb - qa).normalized()
    for f, col in ((0.05, "leather_dark"), (0.62, "leather_dark"), (0.97, "navy")):
        c = qa + (qb - qa) * f
        r = 0.125 + 0.025 * f + 0.02
        up.loft([(0, -0.035, 0, r, r), (0, 0.035, 0, r, r)], col, center=c,
                rotation=Vector((0, 1, 0)).rotation_difference(axis).to_matrix(), segments=12)
    # arrows: shafts and pale-blue fletching above her right shoulder
    for dx, dz, lift in ((-0.06, -0.03, 0.0), (0.05, 0.03, 0.06), (0.0, 0.07, -0.04)):
        top = qb + axis * (0.28 + lift) + Vector((dx, 0, dz))
        up.limb(qb + Vector((dx, -0.1, dz)), top, 0.022, 0.022, "shaft", segments=6, caps=False)
        up.box(top + axis * 0.02, (0.025, 0.16, 0.11), "fletch", bevel=0.015,
               rotation=Vector((0, 1, 0)).rotation_difference(axis).to_matrix())

    low = fb["LowerTorso"]
    # under-tunic (shows through the side slits)
    low.loft([(0, 2.35, 0, 0.55, 0.38), (0, 2.6, 0, 0.59, 0.41), (0, 2.85, 0, 0.53, 0.37), (0, 3.15, 0, 0.44, 0.31)],
             "tunic_dark", power=2.3, segments=16)
    # tunic skirt: front and back panels (slit at the sides), navy hem
    for a0, a1, bottom in ((191, 349, 2.28), (11, 169, 2.2)):
        hem = lambda f: -0.06 * math.sin(math.pi * f)  # noqa: E731
        shell(low, [(0, 3.0, 0, 0.5, 0.35), (0, 2.75, 0, 0.68, 0.46), (0, 2.5, 0, 0.81, 0.53),
                    (0, bottom, 0, 0.87, 0.57)], "tunic", a0, a1, 0.06, segments=14, hem=hem)
        top = bottom + 0.1
        shell(low, [(0, top, 0, 0.85, 0.558), (0, bottom - 0.005, 0, 0.885, 0.582)], "navy",
              a0 - 1, a1 + 1, 0.08, segments=14, hem=hem, fade=False)
    # snowflake sash, knotted at her left hip
    low.loft([(0, 2.82, 0, 0.57, 0.405), (0, 2.97, 0, 0.585, 0.415), (0, 3.12, 0, 0.5, 0.36)], "sash",
             power=2.4, segments=16)
    for x in (-0.22, 0.08, 0.36):
        z = -0.43 + 0.25 * (x / 0.58) ** 2
        snowflake(low, (x, 2.97, z), 0.075, "snow", rotation=(0, math.degrees(math.atan2(x, 0.6)) * -1.2, 0))
    low.sphere((-0.47, 2.93, -0.28), (0.11, 0.1, 0.1), "sash", segments=10, rings=7)
    low.prism([(-0.07, 0), (0.07, 0), (0.09, -0.48), (0.0, -0.42), (-0.06, -0.5)], 0.05, "sash",
              center=(-0.5, 2.9, -0.27), rotation=(0, 55, -8))
    low.prism([(-0.06, 0), (0.06, 0), (0.08, -0.38), (0.0, -0.33), (-0.05, -0.4)], 0.05, "sash",
              center=(-0.54, 2.88, -0.16), rotation=(0, 70, 6))
    snowflake(low, (-0.6, 2.62, -0.23), 0.05, "snow", rotation=(0, 55, 0))


# Arms ------------------------------------------------------------------------------


def arms(fb):
    for side, s in sides():
        ua = fb[f"{side}UpperArm"]
        sh = pivot(f"{side}Shoulder")
        el = pivot(f"{side}Elbow")
        ua.sphere((s * 0.97, 4.12, 0), (0.22, 0.24, 0.24), "tunic", segments=14, rings=9)
        ua.limb((sh[0], sh[1] - 0.05, 0), (el[0], el[1] + 0.05, 0), 0.195, 0.175, "tunic")
        for f in (0.42, 0.72):
            y = sh[1] - 0.05 + (el[1] - sh[1] + 0.1) * f
            x = sh[0] + (el[0] - sh[0]) * (y - sh[1]) / (el[1] - sh[1])
            r = 0.195 - 0.02 * f + 0.008
            ua.loft([(x, y - 0.018, 0, r, r), (x, y + 0.018, 0, r, r)], "tunic_dark", segments=12)

        la = fb[f"{side}LowerArm"]
        wr = pivot(f"{side}Wrist")
        la.limb(el, (s * 1.265, 2.92, 0), 0.175, 0.168, "tunic")
        la.loft([(s * 1.24, 3.08, 0, 0.18, 0.18), (s * 1.245, 3.12, 0, 0.18, 0.18)], "tunic_dark", segments=12)
        # navy cuff trim, short navy gauntlet over the fingerless glove
        la.loft([(s * 1.27, 2.86, 0, 0.19, 0.19), (s * 1.265, 2.95, 0, 0.192, 0.192)], "navy", segments=14)
        la.loft([(s * 1.295, 2.62, 0, 0.165, 0.165), (s * 1.28, 2.87, 0, 0.178, 0.178)], "navy", segments=14)

        # fingerless glove: navy back of the hand, bare curled fingers and thumb
        hand = fb[f"{side}Hand"]
        hand.box((wr[0] + s * 0.035, 2.35, -0.02), (0.29, 0.4, 0.35), "navy", bevel=0.1, segments=2)
        hand.box((wr[0] + s * 0.045, 2.2, -0.09), (0.28, 0.2, 0.29), "skin", bevel=0.075)
        hand.limb((wr[0] - s * 0.09, 2.45, -0.14), (wr[0] - s * 0.12, 2.28, -0.21), 0.068, 0.06, "skin",
                  segments=8)
        hand.loft([(wr[0], 2.53, -0.02, 0.17, 0.19), (wr[0], 2.6, -0.02, 0.165, 0.185)], "navy_light",
                  segments=12)


# Legs ------------------------------------------------------------------------------


def legs(fb):
    for side, s in sides():
        hip = pivot(f"{side}Hip")
        ul = fb[f"{side}UpperLeg"]
        ul.loft([(hip[0], 2.62, 0, 0.27, 0.29), (s * 0.53, 2.1, 0, 0.28, 0.3), (s * 0.52, 1.55, 0, 0.245, 0.265)],
                "navy", segments=14)

        ll = fb[f"{side}LowerLeg"]
        ll.loft([(s * 0.52, 1.58, 0, 0.245, 0.265), (s * 0.52, 1.38, 0, 0.255, 0.27),
                 (s * 0.52, 1.12, 0, 0.22, 0.235)], "navy", segments=14)
        # white boot shaft with a fluffy fur cuff
        ll.loft([(s * 0.52, 0.42, 0.02, 0.2, 0.23), (s * 0.52, 0.75, 0.0, 0.205, 0.235),
                 (s * 0.52, 1.05, 0.0, 0.22, 0.24)], "boot", segments=14)
        fur_ring(ll, (s * 0.52, 1.08, 0.0), 0.2, 0.11, "fur", bumps=7, sides_=5, scale=(1.0, 1.08))
        ll.loft([(s * 0.52, 0.6, 0.0, 0.212, 0.242), (s * 0.52, 0.68, 0.0, 0.215, 0.245)], "navy", segments=14)
        ll.box((s * 0.73, 0.64, -0.03), (0.04, 0.1, 0.1), "silver", bevel=0.012)

        ft = fb[f"{side}Foot"]
        ft.box((s * 0.52, 0.26, -0.1), (0.4, 0.44, 0.74), "boot", bevel=0.14, segments=2, taper=(0.9, 0.75))
        ft.box((s * 0.52, 0.17, -0.35), (0.38, 0.28, 0.3), "boot", bevel=0.12, segments=2)
        ft.box((s * 0.52, 0.05, -0.12), (0.43, 0.1, 0.82), "sole", bevel=0.04)
        ft.box((s * 0.52, 0.42, 0.0), (0.42, 0.07, 0.46), "boot_dark", bevel=0.02)


def model(fb):
    head(fb)
    torso(fb)
    arms(fb)
    legs(fb)
