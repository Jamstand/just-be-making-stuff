"""Moss, jungle druid. Scythe + Spear. Balanced."""

import math

import bmesh
from mathutils import Matrix, Vector

from sky.rig import pivot, sides

NAME = "Moss"

COLORS = {
    "skin": "#6e4129",
    "skin_dark": "#52301d",
    "glow": "#78f25c",
    "glow_light": "#c9ffb4",
    "eye_white": "#f8f4ea",
    "iris": "#5a3417",
    "pupil": "#1c100a",
    "brow": "#1e130d",
    "mouth": "#3b1611",
    "teeth": "#fbf8ef",
    "tongue": "#c4545e",
    "hair": "#2b1d15",
    "hair_light": "#45301f",
    "vine": "#3f8f2f",
    "vine_dark": "#2b6420",
    "leaf": "#62b83c",
    "flower": "#ff8cc0",
    "flower_dark": "#e0609c",
    "pollen": "#ffe066",
    "poncho": "#5b8c35",
    "poncho_dark": "#426a25",
    "poncho_light": "#7aad4a",
    "shirt": "#cdb98c",
    "bark": "#7b654c",
    "bark_dark": "#4d3e2f",
    "bark_light": "#a08a6a",
    "wrap": "#dcc18d",
    "wrap_dark": "#b99a66",
    "rope": "#c9a262",
    "rope_dark": "#a07c42",
    "seed": "#8b5a2b",
    "seed_light": "#b07a3c",
    "trousers": "#6c6c36",
    "trousers_dark": "#52522a",
    "leather": "#a8743f",
    "leather_dark": "#6a4322",
    "sole": "#3a2a1e",
}


# Extra primitives -------------------------------------------------------------


def _catmull(points, values, samples):
    """Catmull-Rom curve through `points`, interpolating `values` linearly."""
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


def sweep(mb, points, radii, color, samples=2, segments=8, hint=None, caps=True, smooth=True):
    """Tube along a smooth curve through `points`; `radii` per point is r or
    (ra, rb) with rb along `hint` (vector or function of the point)."""
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
        rings.append([tmp.verts.new(p + nn * (ra * math.cos(2 * math.pi * k / segments))
                                    + b * (rb * math.sin(2 * math.pi * k / segments)))
                      for k in range(segments)])
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
    mb._finish(tmp, color, (0, 0, 0), None, smooth)


def ring_loft(mb, sections, color, offset=None, teeth=0.0, segments=24, power=2.0, smooth=True,
              center=(0, 0, 0), rotation=None, cap_y=None):
    """Closed loft through rings [(cx, y, cz, rx, rz)] (top to bottom).
    `offset(a)` (a = angle, 0 = +X, pi/2 = +Z behind) moves the bottom edge up
    or down, fading toward the top ring; `teeth` cuts the bottom edge into a
    zig-zag of `segments / 2` points. The bottom is closed with a fan to a
    centre point at `cap_y` (put it inside the body to hide the underside)."""
    tmp = bmesh.new()
    rings = []
    y0, y1 = sections[0][1], sections[-1][1]
    last = len(sections) - 1
    ex = 2.0 / power
    for si, (cx, y, cz, rx, rz) in enumerate(sections):
        w = (y0 - y) / (y0 - y1)
        ring = []
        for k in range(segments):
            a = 2 * math.pi * k / segments
            c, s_ = math.cos(a), math.sin(a)
            yy = y + (offset(a) * w if offset else 0.0)
            if si == last and k % 2 == 0:
                yy -= teeth
            ring.append(tmp.verts.new((cx + rx * math.copysign(abs(c) ** ex, c), yy,
                                       cz + rz * math.copysign(abs(s_) ** ex, s_))))
        rings.append(ring)
    for r0, r1 in zip(rings, rings[1:]):
        for k in range(segments):
            j = (k + 1) % segments
            tmp.faces.new((r0[k], r0[j], r1[j], r1[k]))
    tmp.faces.new(list(reversed(rings[0])))
    cx, y, cz = sections[-1][0], sections[-1][1], sections[-1][2]
    centre = tmp.verts.new((cx, cap_y if cap_y is not None else sum(v.co.y for v in rings[-1]) / segments + 0.05,
                            cz))
    for k in range(segments):
        tmp.faces.new((centre, rings[-1][(k + 1) % segments], rings[-1][k]))
    bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
    mb._finish(tmp, color, center, rotation, smooth)


def frame(normal, up=(0, 1, 0)):
    """Rotation whose local Z is `normal` and local Y leans toward `up`."""
    z = Vector(normal).normalized()
    y = Vector(up)
    y = (y - z * y.dot(z)).normalized()
    x = y.cross(z)
    return Matrix((x, y, z)).transposed()


def leaf_outline(length, width, n=5):
    pts = []
    for i in range(n + 1):
        t = i / n
        pts.append((0.5 * width * math.sin(math.pi * t) ** 0.8, -length / 2 + length * t))
    for i in range(n - 1, 0, -1):
        t = i / n
        pts.append((-0.5 * width * math.sin(math.pi * t) ** 0.8, -length / 2 + length * t))
    return pts


def leaf(mb, pos, normal, up, length, width, color, depth=0.025):
    mb.prism(leaf_outline(length, width), depth, color, center=pos, rotation=frame(normal, up))


def flower(mb, pos, normal, size):
    pts = []
    for i in range(15):
        a = 2 * math.pi * i / 15
        r = size * (0.5 + 0.5 * abs(math.cos(2.5 * a)))
        pts.append((r * math.cos(a), r * math.sin(a)))
    rot = frame(normal, (0, 1, 0.3))
    mb.prism(pts, 0.035, "flower", center=pos, rotation=rot)
    n = Vector(normal).normalized()
    mb.sphere(Vector(pos) + n * 0.025, size * 0.3, "pollen", segments=6, rings=4)


# Head -----------------------------------------------------------------------------

SCALP = ((0, 5.22, 0.02), (0.495, 0.6, 0.545))


def scalp(a, y, out=0.0):
    """Point on the scalp at azimuth `a` (0 = +X, pi/2 = behind) and height y."""
    (cx, cy, cz), (rx, ry, rz) = SCALP
    k = math.sqrt(max(0.0, 1 - ((y - cy) / ry) ** 2))
    return (cx + math.cos(a) * (rx * k + out), y, cz + math.sin(a) * (rz * k + out))


def head(fb):
    h = fb["Head"]
    h.cylinder((0, 4.56, 0.02), 0.15, 0.48, "skin", segments=10)
    h.sphere((0, 5.2, 0.0), (0.47, 0.58, 0.52), "skin", segments=18, rings=12)
    h.sphere((0, 4.96, -0.08), (0.39, 0.33, 0.42), "skin", segments=16, rings=10)
    for _, s in sides():
        h.sphere((s * 0.47, 5.12, 0.04), (0.08, 0.13, 0.1), "skin", segments=8, rings=6)
        h.sphere((s * 0.49, 5.1, 0.04), (0.035, 0.07, 0.05), "skin_dark", segments=6, rings=4)

    # face: bright eyes, raised brows, broad nose, big cheerful grin
    for _, s in sides():
        h.sphere((s * 0.19, 5.14, -0.44), (0.115, 0.12, 0.06), "eye_white", segments=12, rings=8)
        h.sphere((s * 0.18, 5.125, -0.488), (0.075, 0.095, 0.025), "iris", segments=12, rings=8)
        h.sphere((s * 0.178, 5.12, -0.508), (0.04, 0.05, 0.01), "pupil", segments=8, rings=6)
        h.sphere((s * 0.15, 5.16, -0.515), (0.025, 0.025, 0.008), "eye_white", segments=6, rings=4)
        sweep(h, [(s * 0.07, 5.32, -0.47), (s * 0.19, 5.38, -0.47), (s * 0.31, 5.33, -0.42)],
              [(0.035, 0.022), (0.04, 0.025), (0.0, 0.0)], "brow", segments=6, hint=(0, 0, -1))
        # round cheeks pushed up by the grin
        h.sphere((s * 0.25, 4.95, -0.36), (0.12, 0.085, 0.08), "skin", segments=10, rings=6)
    h.sphere((0, 5.0, -0.51), (0.075, 0.06, 0.05), "skin", segments=10, rings=6)
    for _, s in sides():
        h.sphere((s * 0.055, 4.975, -0.52), (0.03, 0.025, 0.025), "skin_dark", segments=6, rings=4)
    # wide D-shaped open grin on a soft muzzle: dark mouth, top teeth, tongue
    h.sphere((0, 4.87, -0.27), (0.3, 0.18, 0.22), "skin", segments=14, rings=8)
    top_cut = [((0, 4.9, 0), (0, -1, 0))]
    h.sphere((0, 4.87, -0.34), (0.23, 0.14, 0.165), "mouth", segments=16, rings=8, clip=top_cut)
    h.sphere((0, 4.87, -0.338), (0.22, 0.14, 0.17), "teeth", segments=16, rings=8,
             clip=top_cut + [((0, 4.84, 0), (0, 1, 0))])
    h.sphere((0, 4.785, -0.42), (0.1, 0.045, 0.07), "tongue", segments=8, rings=5)
    for _, s in sides():
        sweep(h, [(s * 0.2, 4.9, -0.43), (s * 0.25, 4.95, -0.39)], [(0.016, 0.012), (0.0, 0.0)], "mouth",
              segments=5, hint=(0, 0, -1))

    # glowing leaf markings on the cheeks
    for _, s in sides():
        leaf(h, (s * 0.335, 5.0, -0.345), (s * 0.62, 0.0, -0.78), (s * 0.45, 1, 0), 0.17, 0.075, "glow")
        leaf(h, (s * 0.375, 5.13, -0.3), (s * 0.75, 0.1, -0.65), (s * 0.2, 1, 0), 0.1, 0.045, "glow")

    # dreadlocks: high hairline, thick roots pulled up into a vine-tied bundle,
    # then a fountain of chunky dreads spilling out over the top
    hairline = [((0, 5.52, -0.5), (0, 1.0, 0.42))]
    h.sphere(SCALP[0], SCALP[1], "hair", segments=14, rings=10, clip=hairline)
    for k in range(10):
        a = 2 * math.pi * (k + 0.5) / 10
        y0 = 5.52 - 0.42 * (0.545 * math.sin(a) + 0.52) + 0.06
        sweep(h, [scalp(a, y0, 0.02), scalp(a, 5.66, 0.03), (math.cos(a) * 0.17, 5.86, 0.08 + math.sin(a) * 0.17)],
              [0.1, 0.1, 0.085], "hair" if k % 2 else "hair_light", segments=6, samples=2)
    h.loft([(0, 5.7, 0.06, 0.28, 0.28), (0, 5.88, 0.08, 0.2, 0.2), (0, 6.02, 0.08, 0.24, 0.24)], "hair",
           segments=12)
    for y, r in ((5.8, 0.225), (5.92, 0.205)):
        h.torus((0, y, 0.08), r, 0.045, "vine", segments=14, sides=5)
    for k in range(10):
        jit = (0.0, 0.12, -0.1, 0.06, -0.05, 0.14, -0.12, 0.04, 0.1, -0.08)[k]
        a = 2 * math.pi * k / 10 + 0.3 + jit
        c, s_ = math.cos(a), math.sin(a)
        vary = (0.0, 0.14, -0.06, 0.18, 0.02, -0.1, 0.1, -0.03, 0.16, -0.08)[k]
        reach = 0.66 + 0.1 * max(0.0, s_) + vary * 0.4  # longer toward the back
        drop = 5.78 - 0.4 * (0.5 + 0.5 * s_) - vary
        lift = 6.22 + vary * 0.4
        if s_ < -0.6:
            reach, drop = 0.56, 5.96  # short over the face
        pts = [(c * 0.08, 5.98, 0.08 + s_ * 0.08), (c * 0.3, lift, 0.08 + s_ * 0.3),
               (c * reach * 0.8, lift - 0.02, 0.08 + s_ * reach * 0.8), (c * reach, lift - 0.24, 0.08 + s_ * reach),
               (c * (reach + 0.05), drop + 0.08, 0.08 + s_ * (reach + 0.05)),
               (c * (reach + 0.055), drop, 0.08 + s_ * (reach + 0.055))]
        sweep(h, pts, [0.1, 0.12, 0.12, 0.11, 0.1, 0.06], "hair" if k % 2 else "hair_light", segments=6,
              samples=2)
    # a few long dreads hanging down the back
    for x, l in ((-0.2, 0.0), (0.05, 0.12), (0.26, 0.04)):
        sweep(h, [(x * 0.4, 5.92, 0.2), (x * 0.8, 5.84, 0.55), (x, 5.42, 0.66), (x * 1.1, 5.0 - l, 0.64),
                  (x * 1.1, 4.92 - l, 0.62)], [0.1, 0.11, 0.105, 0.1, 0.06], "hair_light" if l else "hair",
              segments=6, samples=2)
    # vines winding through, leaves and small pink flowers
    for a in (0.4, 2.3, 4.2):
        c, s_ = math.cos(a), math.sin(a)
        leaf(h, (c * 0.26, 5.86, 0.08 + s_ * 0.26), (c, 0.3, s_), (c * 0.5, 1, s_ * 0.5), 0.22, 0.11, "leaf")
    for a, y, size in ((-1.0, 5.86, 0.11), (3.6, 5.84, 0.1), (1.2, 5.95, 0.095)):
        c, s_ = math.cos(a), math.sin(a)
        flower(h, (c * 0.24, y, 0.08 + s_ * 0.24), (c, 0.25, s_), size)
    flower(h, (0.4, 6.27, -0.26), (0.35, 0.85, -0.4), 0.1)
    flower(h, (-0.5, 6.22, 0.3), (-0.5, 0.8, 0.3), 0.09)


# Torso ----------------------------------------------------------------------------


def torso(fb):
    up = fb["UpperTorso"]
    # lanky frame in a tan undershirt
    up.loft([(0, 3.0, 0, 0.42, 0.29), (0, 3.4, 0, 0.44, 0.3), (0, 3.9, 0, 0.5, 0.32), (0, 4.25, 0, 0.55, 0.31),
             (0, 4.45, 0, 0.36, 0.24)], "shirt", power=2.3, segments=14)

    # moss-green poncho: long leaf-cut flaps front and back...
    ring_loft(up, [(0, 4.52, 0.02, 0.4, 0.33), (0, 4.35, 0.02, 0.7, 0.47), (0, 4.1, 0.03, 0.8, 0.52),
                   (0, 3.7, 0.03, 0.84, 0.55), (0, 3.25, 0.03, 0.86, 0.6)],
              "poncho", offset=lambda a: 0.33 * math.cos(2 * a), teeth=0.16, segments=32, power=2.2, cap_y=4.0)
    # ...under a leaf-cut mantle that drapes over the shoulders
    ring_loft(up, [(0, 4.6, 0.02, 0.43, 0.35), (0, 4.48, 0.02, 0.82, 0.52), (0, 4.3, 0.03, 1.13, 0.6),
                   (0, 4.05, 0.03, 1.32, 0.65), (0, 3.86, 0.03, 1.38, 0.68)],
              "poncho_light", offset=lambda a: -0.12 * math.sin(a) ** 2, teeth=0.15, segments=32, power=2.0,
              cap_y=4.3)
    # cowl and the hood folded down behind
    up.torus((0, 4.62, 0.03), 0.3, 0.09, "poncho_dark", segments=14, sides=6, scale=(1.05, 1.0))
    up.sphere((0, 4.5, 0.53), (0.42, 0.3, 0.2), "poncho", segments=14, rings=8)
    up.sphere((0, 4.56, 0.44), (0.26, 0.14, 0.1), "poncho_dark", segments=12, rings=6)

    low = fb["LowerTorso"]
    low.loft([(0, 2.3, 0, 0.48, 0.33), (0, 2.6, 0, 0.5, 0.35), (0, 2.85, 0, 0.45, 0.32), (0, 3.15, 0, 0.41, 0.28)],
             "trousers", power=2.3, segments=14)
    # rope belt slung on the hips, seed-pod charms
    low.torus((0, 2.68, 0.0), 0.5, 0.045, "rope", segments=18, sides=6, scale=(1.03, 0.72))
    low.torus((0, 2.72, 0.0), 0.5, 0.035, "rope_dark", segments=18, sides=5, scale=(1.02, 0.71))
    for x, l in ((-0.32, 0.26), (-0.12, 0.2), (0.2, 0.3), (0.42, 0.22)):
        z = -0.36 * math.sqrt(max(0.0, 1 - (x / 0.54) ** 2)) - 0.02
        low.limb((x, 2.66, z), (x, 2.66 - l + 0.06, z - 0.02), 0.012, 0.012, "rope_dark", segments=5, caps=False)
        low.sphere((x, 2.66 - l, z - 0.02), (0.05, 0.08, 0.05), "seed", segments=8, rings=6)
        low.sphere((x, 2.66 - l - 0.06, z - 0.03), (0.025, 0.03, 0.025), "seed_light", segments=6, rings=4)
    low.box((0.45, 2.62, -0.2), (0.05, 0.14, 0.05), "rope", bevel=0.015, rotation=(0, 0, -10))


# Arms ------------------------------------------------------------------------------


def arms(fb):
    for side, s in sides():
        ua = fb[f"{side}UpperArm"]
        sh = pivot(f"{side}Shoulder")
        el = pivot(f"{side}Elbow")
        ua.sphere((s * 0.98, 4.12, 0), (0.2, 0.22, 0.21), "skin", segments=12, rings=8)
        ua.limb((sh[0], sh[1] - 0.05, 0), (el[0], el[1] + 0.05, 0), 0.165, 0.145, "skin")
        # glowing leaf markings along the outer arm (below the mantle)
        ax = (Vector(el) - Vector(sh)).normalized()
        for f, sz in ((0.68, 0.15), (0.9, 0.12)):
            c = Vector(sh) + (Vector(el) - Vector(sh)) * f
            r = 0.165 - 0.02 * f
            leaf(ua, c + Vector((s * (r - 0.005), 0, -0.02)), (s, 0.1, -0.15), -ax + Vector((0, 0, -0.4)),
                 sz, sz * 0.45, "glow")
        if side == "Right":
            # bark pauldron over the mantle: a dome with a jagged rim, grooves and a sprout
            pc, tilt = Vector((1.12, 4.3, 0.0)), -34
            rot = Matrix.Rotation(math.radians(tilt), 3, "Z")
            ring_loft(ua, [(0, 0.17, 0, 0.12, 0.13), (0, 0.13, 0, 0.26, 0.29), (0, 0.05, 0, 0.34, 0.38),
                           (0, -0.08, 0, 0.37, 0.41)], "bark", teeth=0.07, segments=20, center=pc,
                      rotation=(0, 0, tilt))
            ring_loft(ua, [(0, -0.02, 0, 0.345, 0.385), (0, -0.09, 0, 0.37, 0.41)], "bark_dark", teeth=0.05,
                      segments=20, center=pc, rotation=(0, 0, tilt))
            for deg, bend, start in ((-140, 12, 0.2), (-95, -10, 0.45), (-45, 15, 0.1), (10, -12, 0.5),
                                     (70, 10, 0.15), (125, -15, 0.4), (175, 8, 0.3)):
                pts = []
                for t in (start, (start + 1) / 2, 1.0):
                    a = math.radians(deg + bend * t)
                    rr = 0.13 + 0.235 * t
                    pts.append(pc + rot @ Vector((rr * math.cos(a), 0.17 - 0.2 * t ** 1.4, rr * 1.1 * math.sin(a))))
                sweep(ua, pts, [0.02, 0.026, 0.022], "bark_dark", segments=5, samples=1)
            sprout = pc + rot @ Vector((0, 0.2, 0))
            ua.limb(sprout, sprout + Vector((-0.03, 0.16, 0.0)), 0.03, 0.025, "vine_dark", segments=6)
            leaf(ua, sprout + Vector((-0.09, 0.2, -0.06)), (-0.3, 0.5, -0.8), (-0.4, 1, -0.2), 0.2, 0.1, "leaf")
            leaf(ua, sprout + Vector((0.02, 0.2, 0.06)), (0.3, 0.5, 0.8), (0.5, 1, 0.2), 0.17, 0.085, "leaf")
        la = fb[f"{side}LowerArm"]
        wr = pivot(f"{side}Wrist")
        la.limb(el, (s * 1.25, 3.0, 0), 0.145, 0.14, "skin")
        leaf(la, (s * 1.36, 3.2, -0.03), (s, 0, -0.15), (0, -1, -0.3), 0.14, 0.06, "glow")
        # tan cloth wraps with diagonal bands
        la.loft([(s * 1.295, 2.6, 0, 0.15, 0.15), (s * 1.28, 2.8, 0, 0.165, 0.165),
                 (s * 1.255, 3.05, 0, 0.16, 0.16)], "wrap", segments=12)
        for y, tilt in ((2.68, 14), (2.82, -14), (2.96, 14)):
            la.loft([(0, -0.025, 0, 0.17, 0.17), (0, 0.025, 0, 0.17, 0.17)], "wrap_dark",
                    center=(s * 1.28, y, 0), rotation=(tilt, 0, 0), segments=12)

        hand = fb[f"{side}Hand"]
        hand.box((wr[0] + s * 0.04, 2.33, -0.02), (0.31, 0.43, 0.37), "skin", bevel=0.11, segments=2)
        hand.box((wr[0] + s * 0.05, 2.17, -0.1), (0.29, 0.16, 0.26), "skin", bevel=0.07)
        hand.limb((wr[0] - s * 0.1, 2.46, -0.15), (wr[0] - s * 0.13, 2.27, -0.23), 0.075, 0.065, "skin",
                  segments=8)
        hand.loft([(wr[0], 2.5, -0.02, 0.165, 0.18), (wr[0], 2.6, -0.02, 0.155, 0.17)], "wrap", segments=12)


# Legs ------------------------------------------------------------------------------


def legs(fb):
    for side, s in sides():
        hip = pivot(f"{side}Hip")
        ul = fb[f"{side}UpperLeg"]
        ul.loft([(hip[0], 2.62, 0, 0.25, 0.26), (s * 0.52, 2.1, 0, 0.225, 0.235), (s * 0.52, 1.55, 0, 0.2, 0.21)],
                "trousers", segments=12)
        ul.box((s * 0.725, 2.05, 0.0), (0.06, 0.34, 0.22), "trousers_dark", bevel=0.02)

        ll = fb[f"{side}LowerLeg"]
        ll.loft([(s * 0.52, 1.58, 0, 0.2, 0.21), (s * 0.52, 1.35, 0, 0.205, 0.215),
                 (s * 0.52, 1.15, 0, 0.2, 0.21)], "trousers", segments=12)
        # rolled cuff, bare shin, wrapped leather sandal-boot
        ll.loft([(s * 0.52, 1.03, 0, 0.21, 0.22), (s * 0.52, 1.11, 0, 0.235, 0.245),
                 (s * 0.52, 1.21, 0, 0.225, 0.235)], "trousers_dark", segments=12)
        ll.limb((s * 0.52, 1.06, 0.0), (s * 0.52, 0.55, 0.0), 0.135, 0.13, "skin", caps=False)
        ll.loft([(s * 0.52, 0.42, 0.02, 0.18, 0.2), (s * 0.52, 0.52, 0.0, 0.165, 0.18),
                 (s * 0.52, 0.64, 0.0, 0.15, 0.16)], "leather", segments=12)
        # criss-cross leather wraps climbing the bare shin
        for y, tilt in ((0.7, 18), (0.8, -18), (0.9, 18), (0.99, -16)):
            ll.loft([(0, -0.022, 0, 0.147, 0.155), (0, 0.022, 0, 0.147, 0.155)], "leather",
                    center=(s * 0.52, y, 0), rotation=(tilt, 0, 0), segments=12)
        ll.loft([(0, -0.02, 0, 0.18, 0.195), (0, 0.02, 0, 0.18, 0.195)], "leather_dark",
                center=(s * 0.52, 0.53, 0), rotation=(-12, 0, 0), segments=12)

        ft = fb[f"{side}Foot"]
        ft.box((s * 0.52, 0.25, -0.06), (0.4, 0.4, 0.62), "leather", bevel=0.13, segments=2, taper=(0.9, 0.8))
        ft.box((s * 0.52, 0.15, -0.36), (0.38, 0.22, 0.26), "skin", bevel=0.09, segments=2)
        ft.box((s * 0.52, 0.2, -0.27), (0.42, 0.08, 0.1), "leather_dark", bevel=0.025)
        ft.box((s * 0.52, 0.05, -0.12), (0.44, 0.1, 0.84), "sole", bevel=0.04)
        ft.box((s * 0.52, 0.4, -0.05), (0.42, 0.07, 0.42), "leather_dark", bevel=0.02, rotation=(12, 0, 0))


def model(fb):
    head(fb)
    torso(fb)
    arms(fb)
    legs(fb)
