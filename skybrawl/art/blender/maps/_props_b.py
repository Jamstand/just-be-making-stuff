"""
Small prop helpers shared by the VolcanicForge and JungleTemple map kits.
Everything works on a MeshBuilder piece in arena space (X right, Y up,
Z toward the camera). Private to those two maps.
"""

import math
import os
import random

from mathutils import Matrix, Vector


def rng(seed):
    return random.Random(seed)


def chain(p, a, b, color, pitch=1.1, thick=0.14, phase=0):
    """Iron chain from a to b: links alternate between facing the camera and
    being seen edge-on."""
    a, b = Vector(a), Vector(b)
    d = b - a
    length = d.length
    d.normalize()
    ref = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    n1 = (ref - d * ref.dot(d)).normalized()
    n2 = d.cross(n1).normalized()
    count = max(1, int(round(length / pitch)))
    step = length / count
    radius = step * 0.62
    for i in range(count):
        c = a + d * (step * (i + 0.5))
        if (i + phase) % 2 == 0:
            # ring facing the camera
            u = n1.cross(d).normalized()
            rot = Matrix((u, n1, d)).transposed()
            p.torus(c, radius, thick, color, rotation=rot, segments=8, sides=4, scale=(0.55, 1.0))
        else:
            # link seen edge-on: a thin bar is enough
            rot = Matrix((n2, d, n1)).transposed()
            p.box(c, (thick * 2, (radius + thick) * 2, (radius * 0.55 + thick) * 2), color, bevel=0, rotation=rot)


def rope(p, a, b, color, radius=0.12, sag=0.0, segments=6, pieces=6):
    """Rope from a to b, optionally sagging downward in the middle."""
    a, b = Vector(a), Vector(b)
    pts = []
    for i in range(pieces + 1):
        t = i / pieces
        q = a.lerp(b, t)
        q.y -= sag * 4 * t * (1 - t)
        pts.append(q)
    for q0, q1 in zip(pts, pts[1:]):
        axis = q1 - q0
        rot = Vector((0, 1, 0)).rotation_difference(axis.normalized()).to_matrix()
        p.cylinder((q0 + q1) / 2, radius, axis.length + radius, color, rotation=rot, segments=segments)


def hexcol(p, x, z, r, y0, y1, color, turn=0.0, top=None, top_h=0.3):
    """Hexagonal basalt column from y0 up to y1 (flat side toward the camera).
    `top` adds a lighter cap so the column tops read."""
    p.cylinder((x, (y0 + y1) / 2, z), r, y1 - y0, color, rotation=(0, turn, 0), segments=6, smooth=False)
    if top:
        p.cylinder((x, y1 - top_h / 2 + 0.02, z), r * 1.02, top_h, top, rotation=(0, turn, 0), segments=6,
                   smooth=False)


def blob(p, center, radii, color, segments=10, rings=6, rotation=None):
    p.sphere(center, radii, color, segments=segments, rings=rings, rotation=rotation)


def puffs(p, center, scale, color, r, count=5, flat=0.75, spread=(1.6, 0.5, 0.6), segments=10, rings=6):
    """Cluster of round toon puffs (clouds, smoke, foliage)."""
    cx, cy, cz = center
    out = []
    for i in range(count):
        t = (i / max(1, count - 1)) * 2 - 1 if count > 1 else 0
        rad = scale * (0.75 + r.random() * 0.45) * (1.0 - 0.3 * abs(t))
        c = (cx + t * scale * spread[0] + r.uniform(-0.2, 0.2) * scale,
             cy + r.uniform(-spread[1], spread[1]) * scale + (1 - abs(t)) * scale * 0.35,
             cz + r.uniform(-spread[2], spread[2]) * scale)
        p.sphere(c, (rad, rad * flat, rad * 0.85), color, segments=segments, rings=rings)
        out.append((c, rad))
    return out


def stream(p, pts, color, segments=7, power=2.0, smooth=True):
    """A tube through [(x, y, z, rx, rz), ...] (top to bottom or any order);
    sections are horizontal rings. Used for lava/water falls and pillars."""
    p.loft(pts, color, segments=segments, power=power, smooth=smooth, caps=(True, True))


def fall(p, x, y_top, y_bot, z, width, color, r, wobble=0.6, depth=0.5, steps=7, spread=1.6):
    """A falling ribbon (lava fall, waterfall) that widens as it drops."""
    pts = []
    for i in range(steps + 1):
        t = i / steps
        y = y_top + (y_bot - y_top) * t
        w = width * (1 + (spread - 1) * t)
        dx = r.uniform(-wobble, wobble) * t if 0 < i < steps else 0
        pts.append((x + dx, y, z, w / 2, depth))
    stream(p, pts, color, segments=8, power=3.0)


def rock_bottom(p, cx, cz, y_top, width, depth, drop, color, r, segments=8, jitter=0.18, tip=0.0):
    """Faceted inverted-cone rock under a floating island. Returns the list of
    ring sections (x, y, z, rx, rz)."""
    secs = []
    steps = 5
    for i in range(steps + 1):
        t = i / steps
        k = (1 - t) ** 1.25
        y = y_top - drop * t
        jx = r.uniform(-jitter, jitter) * width * 0.25 * t
        jz = r.uniform(-jitter, jitter) * depth * 0.2 * t
        if i == steps:
            secs.append((cx + jx, y, cz + jz, tip, tip))
        else:
            secs.append((cx + jx, y, cz + jz, width / 2 * k, depth / 2 * k))
    p.loft(secs, color, segments=segments, power=2.0, smooth=False)
    return secs


def outline_jagged(r, x1, x2, y_top, y_bot, teeth=6, inset=0.25, wiggle=0.6):
    """2D outline (for prism) of a cliff shape: flat top from x1 to x2 at
    y_top, sides that pinch in, and a jagged bottom around y_bot."""
    w = x2 - x1
    pts = [(x1, y_top), (x2, y_top)]
    pts.append((x2 - w * inset * 0.3, y_top + (y_bot - y_top) * 0.45))
    for i in range(teeth, -1, -1):
        t = i / teeth
        x = x2 - w * inset * 0.5 - (w * (1 - inset)) * (1 - t)
        dip = (y_bot - y_top) * (0.75 + 0.25 * math.sin(t * math.pi)) + r.uniform(-wiggle, wiggle)
        if i % 2 == 0:
            dip += abs(wiggle) * 1.5
        pts.append((x, y_top + dip))
    pts.append((x1 + w * inset * 0.3, y_top + (y_bot - y_top) * 0.45))
    return pts


def ridge_outline(r, x1, x2, base, peaks):
    """Mountain-range silhouette: [(x, height), ...] peaks between x1 and x2."""
    pts = [(x1, base)]
    for x, h in peaks:
        pts.append((x, base + h))
    pts.append((x2, base))
    return pts


def zigzag(r, x, y_top, y_bot, width=0.3, kinks=5, amp=0.6):
    """Thin zigzag crack outline running from y_top down to y_bot."""
    left, right = [], []
    for i in range(kinks + 1):
        t = i / kinks
        y = y_top + (y_bot - y_top) * t
        cx = x + (r.uniform(-amp, amp) if 0 < i < kinks else 0)
        w = width * (1 - 0.7 * t) if i < kinks else 0.02
        left.append((cx - w / 2, y))
        right.append((cx + w / 2, y))
    return right + list(reversed(left))


def star(p, center, size, color):
    """Little diamond spark (ember, firefly, dust mote)."""
    p.sphere(center, (size * 0.7, size, size * 0.7), color, segments=4, rings=3)


def dev_figures(mb, spots, color):
    """Fighter-sized stand-ins (6 studs) for checking scale in previews.
    Only built when SKYBRAWL_DEV_FIGURES=1."""
    if os.environ.get("SKYBRAWL_DEV_FIGURES") != "1":
        return
    p = mb.piece("DevFigures")
    for x, y in spots:
        p.capsule((x, y + 1.0, 0), (x, y + 4.6, 0), 1.0, color)
        p.sphere((x, y + 5.3, 0), 0.8, color)


# Foliage ---------------------------------------------------------------------


def euler_matrix(rotation):
    rx, ry, rz = (math.radians(d) for d in rotation)
    return Matrix.Rotation(rx, 3, "X") @ Matrix.Rotation(ry, 3, "Y") @ Matrix.Rotation(rz, 3, "Z")


def leaf_outline(length, width, notch=False):
    """Broad pointed leaf along local +Y from the stem at the origin."""
    pts = [(0.0, 0.0), (width * 0.42, length * 0.18), (width * 0.5, length * 0.42), (width * 0.38, length * 0.7),
           (width * 0.16, length * 0.9), (0.0, length), (-width * 0.16, length * 0.9), (-width * 0.38, length * 0.7),
           (-width * 0.5, length * 0.42), (-width * 0.42, length * 0.18)]
    if notch:
        pts = [pts[0], pts[1], (width * 0.22, length * 0.3), pts[2], pts[3], (width * 0.1, length * 0.66), pts[4],
               pts[5], pts[6], pts[7], pts[8], (-width * 0.2, length * 0.52), pts[9]]
    return pts


def leaf(p, base, length, width, color, angle=0.0, tilt=0.0, rib=None, notch=False, thick=0.2):
    """Flat toon leaf at `base`, pointing at `angle` degrees from straight up
    (positive = toward -X), tilted `tilt` degrees about X."""
    rot = (tilt, 0.0, angle)
    p.prism(leaf_outline(length, width, notch), thick, color, center=base, rotation=rot)
    if rib:
        m = euler_matrix(rot)
        off = m @ Vector((0, 0, thick * 0.5 + 0.03))
        c = Vector(base) + off
        p.prism([(-width * 0.035, 0.0), (width * 0.035, 0.0), (0.0, length * 0.85)], 0.06, rib, center=tuple(c),
                rotation=rot)


def leaf_fan(p, base, size, colors, r, count=5, spread=110.0, tilt=12.0, rib=None, notch=False, aim=0.0):
    """A clump of big jungle leaves fanning out from one point, centered on
    `aim` degrees from straight up."""
    for i in range(count):
        t = i / max(1, count - 1) - 0.5
        a = aim + t * spread + r.uniform(-8, 8)
        ln = size * (1.0 - abs(t) * 0.5) * r.uniform(0.85, 1.1)
        leaf(p, (base[0], base[1], base[2] + (0.5 - abs(t)) * 0.3), ln, ln * 0.55, colors[i % len(colors)],
             angle=a, tilt=tilt + r.uniform(-6, 6), rib=rib, notch=notch and i % 2 == 0)


def palm(p, base, height, lean, trunk, trunk_dark, frond_colors, r, fronds=7, frond_len=None):
    """Curved palm: banded trunk leaning `lean` studs sideways at the top."""
    x0, y0, z0 = base
    steps = 7
    pts = []
    for i in range(steps + 1):
        t = i / steps
        pts.append(Vector((x0 + lean * t * t, y0 + height * t, z0)))
    for i, (a, b) in enumerate(zip(pts, pts[1:])):
        r1 = 0.9 - 0.4 * i / steps
        p.limb(a, b, r1, r1 - 0.06, trunk if i % 2 == 0 else trunk_dark, segments=7, caps=False)
    top = pts[-1]
    p.sphere(tuple(top), 0.9, trunk_dark, segments=8, rings=5)
    fl = frond_len or height * 0.45
    for i in range(fronds):
        a = -150 + i * (300 / max(1, fronds - 1)) + r.uniform(-10, 10)
        tilt = r.uniform(-25, 25)
        col = frond_colors[i % len(frond_colors)]
        # inner part rises, outer part droops
        leaf(p, tuple(top), fl * 0.55, fl * 0.22, col, angle=a * 0.55, tilt=tilt, thick=0.18)
        m = euler_matrix((tilt, 0.0, a * 0.55))
        tip = top + m @ Vector((0, fl * 0.5, 0))
        leaf(p, tuple(tip), fl * 0.6, fl * 0.2, col, angle=a * 0.55 + math.copysign(55, a), tilt=tilt, thick=0.18)
    return top


def broadleaf_tree(p, base, height, trunk, canopy_colors, r, spread=1.0, lean=0.0, puffs_n=6):
    """Round-canopied jungle tree: tapered trunk, two forks, puffy crown."""
    x0, y0, z0 = base
    top = Vector((x0 + lean, y0 + height, z0))
    p.limb((x0, y0, z0), tuple(top), 1.2 * spread, 0.7 * spread, trunk, segments=8, caps=False)
    for side in (-1, 1):
        q = top + Vector((side * 3.0 * spread, 2.5 * spread, r.uniform(-1, 1)))
        p.limb(tuple(top), tuple(q), 0.7 * spread, 0.4 * spread, trunk, segments=7, caps=False)
    out = []
    for i in range(puffs_n):
        t = (i / max(1, puffs_n - 1)) * 2 - 1
        rad = (4.2 + r.random() * 1.6) * spread * (1 - 0.25 * abs(t))
        c = (top.x + t * 5.5 * spread, top.y + 3.0 * spread + (1 - abs(t)) * 2.2 * spread + r.uniform(-0.8, 0.8),
             z0 + r.uniform(-2.0, 1.0))
        p.sphere(c, (rad, rad * 0.78, rad * 0.9), canopy_colors[i % len(canopy_colors)], segments=12, rings=7)
        out.append((c, rad))
    return top, out


def vine(p, top, length, color, leaf_color, r, sway=0.6, leaves=4, thick=0.12, z_leaf=0.15):
    """Hanging vine with a few small leaves."""
    x, y, z = top
    pts = []
    n = 5
    for i in range(n + 1):
        t = i / n
        pts.append((x + math.sin(t * 3.0 + x) * sway * t, y - length * t, z))
    for a, b in zip(pts, pts[1:]):
        p.limb(a, b, thick, thick * 0.9, color, segments=5, caps=False)
    for i in range(leaves):
        t = (i + 0.7) / (leaves + 0.5)
        k = min(n - 1, int(t * n))
        a, b = Vector(pts[k]), Vector(pts[k + 1])
        q = a.lerp(b, t * n - k)
        side = 1 if i % 2 else -1
        leaf(p, (q.x, q.y, q.z + z_leaf), 0.9 + r.random() * 0.4, 0.55, leaf_color, angle=side * 115,
             tilt=0, thick=0.08)
