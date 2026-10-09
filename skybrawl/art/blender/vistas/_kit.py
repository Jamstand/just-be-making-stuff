"""
Props for the painted background vistas (sky/vista.py). Everything works in
arena space on a MeshBuilder piece (vista.piece(layer, group)); sizes are
world units, so a scene sizes a prop from how much of the screen it should
cover at its depth (Vista.unit).

Pieces in a layer's "Glow" group are lit windows and lamps (unshaded and
bright); "Cloud" pieces get the softer cloud tones.
"""

import math
import random

from maps import _props_a as P


def rng(seed):
    return random.Random(seed)


# Clouds ---------------------------------------------------------------------


def cumulus(p, center, width, color, r, height=1.0, depth=0.55, puffs=7):
    """A toon cumulus `width` across: a flat base, a row of big puffs and
    smaller ones piling up toward the middle. `height` stretches it into a
    towering cloud."""
    cx, cy, cz = center
    w = width
    p.sphere((cx, cy + w * 0.03, cz), (w * 0.52, w * 0.07, w * 0.5 * depth), color, segments=18, rings=8)
    rows = ((puffs, 0.15, 0.42, 0.0), (max(2, puffs - 2), 0.13, 0.3, 0.13), (max(1, puffs - 4), 0.11, 0.17, 0.25))
    for count, radius, spread, lift in rows:
        for i in range(count):
            t = (i + 0.5) / count - 0.5 if count > 1 else 0.0
            hump = 1 - abs(t) * 1.5
            rad = w * radius * (0.75 + 0.45 * hump) * r.uniform(0.85, 1.15)
            x = cx + t * w * spread * 2 + r.uniform(-0.03, 0.03) * w
            y = cy + w * (0.05 + lift * height) + rad * 0.3 * hump
            z = cz + r.uniform(-0.18, 0.18) * w * depth
            p.sphere((x, y, z), (rad * 1.12, rad * (0.92 + 0.2 * (height - 1)), rad * depth * 1.5), color,
                     segments=14, rings=9)


def streak(p, center, length, color, thickness=0.028, depth=0.03):
    """A flat streak of high cloud."""
    x, y, z = center
    p.sphere((x, y, z), (length * 0.5, length * thickness, length * depth), color, segments=16, rings=6)


def cloud_row(p, v, us, vs, depth, width_frac, color, r, height=1.0, jitter=0.04):
    """Cumulus along screen positions (us[i], vs[i]) at `depth`."""
    for u, sv in zip(us, vs):
        d = depth * r.uniform(0.9, 1.15)
        cumulus(p, v.at(u + r.uniform(-jitter, jitter), sv, d), width_frac * v.unit(d) * r.uniform(0.8, 1.2),
                color, r, height=height)


# Ground ---------------------------------------------------------------------


def island(p, center, size, colors, r, segments=11):
    """Grass-topped floating rock (colors = top, top_dark, rock, rock_dark).
    Returns the y of its top surface."""
    P.floating_island(p, center, size, colors, r, segments=segments)
    return center[1] + 0.09 * size


def tree(p, base, scale, r, leaves="leaves", leaves_dark="leaves_dark", trunk="trunk"):
    P.round_tree(p, base, scale, trunk, leaves, leaves_dark, r)


# Buildings ------------------------------------------------------------------


def house(p, glow, base, w, h, d, wall, roof, roof_h=None, windows="window", chimney=None):
    x, y, z = base
    rh = roof_h if roof_h is not None else w * 0.5
    p.box((x, y + h / 2, z), (w, h, d), wall, bevel=w * 0.03, segments=1)
    p.wedge((x, y + h + rh / 2 - w * 0.02, z), (w * 1.16, rh, d * 1.16), roof)
    if chimney:
        p.box((x + w * 0.28, y + h + rh * 0.55, z - d * 0.15), (w * 0.12, rh * 0.8, w * 0.12), chimney, bevel=0)
    if windows and glow is not None:
        for dx in (-0.22, 0.22):
            glow.box((x + dx * w, y + h * 0.55, z + d / 2 + w * 0.01), (w * 0.15, h * 0.24, w * 0.02), windows,
                     bevel=0)


def tower(p, glow, base, radius, height, wall, roof, band=None, windows="window"):
    x, y, z = base
    p.cylinder((x, y + height / 2, z), radius, height, wall, segments=12)
    if band:
        p.cylinder((x, y + height * 0.92, z), radius * 1.12, height * 0.08, band, segments=12)
    p.cone((x, y + height + radius * 1.1, z), radius * 1.35, radius * 2.4, roof, segments=12)
    if windows and glow is not None:
        glow.box((x, y + height * 0.62, z + radius * 0.98), (radius * 0.35, height * 0.12, radius * 0.06),
                 windows, bevel=0)


def lighthouse(p, glow, base, height, stripes=("white", "stripe"), cap="roof_red", lamp="lamp", metal="iron"):
    """Striped tapering tower with a gallery, a glowing lamp and a cap."""
    x, y, z = base
    r0, r1 = height * 0.09, height * 0.06
    bands = 5
    body = height * 0.78
    for i in range(bands):
        t0, t1 = i / bands, (i + 1) / bands
        ra, rb = r0 + (r1 - r0) * t0, r0 + (r1 - r0) * t1
        p.cylinder((x, y + body * (t0 + t1) / 2, z), ra, body / bands, stripes[i % 2], segments=14, radius_top=rb)
    top = y + body
    p.cylinder((x, top + height * 0.015, z), r1 * 1.45, height * 0.03, metal, segments=14)
    P.rod(p, (x - r1 * 1.4, top + height * 0.03, z), (x + r1 * 1.4, top + height * 0.03, z), height * 0.004, metal)
    glow.cylinder((x, top + height * 0.08, z), r1 * 0.85, height * 0.1, lamp, segments=12)
    p.cone((x, top + height * 0.17, z), r1 * 1.25, height * 0.09, cap, segments=12)
    p.sphere((x, top + height * 0.225, z), r1 * 0.22, metal, segments=8, rings=6)
    return (x, top + height * 0.08, z)


def dock(p, glow, start, length, width, direction=1, wood="wood", post="wood_dark", lantern="lantern"):
    """Plank pier sticking out sideways from `start` (its near end)."""
    x, y, z = start
    cx = x + direction * length / 2
    p.box((cx, y, z), (length, width * 0.16, width), wood, bevel=width * 0.03, segments=1)
    P.rod(p, (x, y - width * 1.2, z), (x + direction * length * 0.45, y - width * 0.1, z), width * 0.06, post,
          segments=5)
    for k in (0.35, 0.95):
        px = x + direction * length * k
        p.box((px, y + width * 0.45, z + width * 0.45), (width * 0.07, width * 0.9, width * 0.07), post, bevel=0)
        glow.sphere((px, y + width * 0.95, z + width * 0.45), width * 0.12, lantern, segments=8, rings=6)


def bridge(p, a, b, planks="wood", rope="wood_dark", sag=0.12, count=12):
    """Sagging rope bridge from a to b."""
    ax, ay, az = a
    bx, by, bz = b
    length = math.dist(a, b)
    pts = []
    for i in range(count + 1):
        t = i / count
        pts.append((ax + (bx - ax) * t, ay + (by - ay) * t - length * sag * 4 * t * (1 - t), az + (bz - az) * t))
    w = length / count
    for q0, q1 in zip(pts, pts[1:]):
        mid = tuple((c0 + c1) / 2 for c0, c1 in zip(q0, q1))
        p.box(mid, (w * 0.8, w * 0.12, w * 1.4), planks, bevel=0)
    for dz in (-0.75, 0.75):
        for q0, q1 in zip(pts, pts[1:]):
            P.rod(p, (q0[0], q0[1] + w * 0.6, q0[2] + dz * w), (q1[0], q1[1] + w * 0.6, q1[2] + dz * w), w * 0.05,
                  rope, segments=4)


def pennant(p, top, length, color, pole="wood_dark", direction=1):
    x, y, z = top
    P.rod(p, (x, y - length * 1.6, z), (x, y, z), length * 0.04, pole, segments=5)
    p.prism([(x, y), (x + direction * length, y - length * 0.18), (x, y - length * 0.36)], length * 0.03, color,
            center=(0, 0, z))


# Ships ----------------------------------------------------------------------


def airship(p, glow, center, length, balloon, stripe, hull="hull", sail="sail", trim="gold", facing=1,
            lantern="lantern", metal="iron"):
    """A fantasy airship `length` long, nose toward +x (facing=1) or -x: a
    striped balloon with tail fins over a wooden gondola with side sails."""
    x, y, z = center
    L = length
    f = facing
    br = L * 0.17  # balloon radius
    by = y + L * 0.14
    p.sphere((x, by, z), (L * 0.5, br, br), balloon, segments=20, rings=12)
    for k in (-0.28, 0.0, 0.28):
        rr = br * math.sqrt(max(0.0, 1 - (k / 0.5) ** 2)) * 1.01
        p.torus((x + k * L, by, z), rr, L * 0.012, stripe, rotation=(0, 0, 90), segments=20, sides=5)
    tail = x - f * L * 0.43
    fin = [(0, 0), (-f * L * 0.16, L * 0.0), (-f * L * 0.22, L * 0.15), (-f * L * 0.04, L * 0.02)]
    p.prism([(tail + a, by + br * 0.35 + b) for a, b in fin], L * 0.015, stripe, center=(0, 0, z))
    p.prism([(tail + a, by - br * 0.35 - b) for a, b in fin], L * 0.015, stripe, center=(0, 0, z))
    for side in (-1, 1):
        p.prism([(a, b) for a, b in fin], L * 0.015, stripe, center=(tail, by, z + side * br * 0.35),
                rotation=(90 * side, 0, 0))
    gy = y - L * 0.08
    p.box((x + f * L * 0.02, gy, z), (L * 0.46, L * 0.075, L * 0.12), hull, bevel=L * 0.02, segments=2,
          taper=(1.12, 1.15))
    p.cone((x + f * L * 0.29, gy + L * 0.005, z), L * 0.045, L * 0.12, hull, rotation=(0, 0, -90 * f), segments=8)
    p.box((x + f * L * 0.02, gy + L * 0.045, z), (L * 0.48, L * 0.012, L * 0.13), trim, bevel=0)
    for dx in (-0.16, 0.18):
        for dz in (-1, 1):
            P.rod(p, (x + dx * L, gy + L * 0.04, z + dz * L * 0.05), (x + dx * L * 1.2, by - br * 0.85, z + dz * br * 0.4),
                  L * 0.005, metal, segments=4)
    for side in (-1, 1):
        wing = [(0, 0), (f * L * 0.2, L * 0.02), (f * L * 0.06, L * 0.16)]
        p.prism([(x - f * L * 0.08 + a, gy + L * 0.02 + b) for a, b in wing], L * 0.008, sail,
                center=(0, 0, z + side * L * 0.075))
    hub = (x - f * L * 0.23, gy, z)
    p.cylinder(hub, L * 0.018, L * 0.04, metal, rotation=(0, 0, 90), segments=8)
    for k in range(3):
        a = math.radians(30 + 120 * k)
        p.box((hub[0] - f * L * 0.02, hub[1] + math.sin(a) * L * 0.05, hub[2] + math.cos(a) * L * 0.05),
              (L * 0.008, L * 0.09, L * 0.025), trim, rotation=(math.degrees(a), 0, 0), bevel=0)
    for dx in (0.22, -0.2):
        glow.sphere((x + f * L * dx, gy + L * 0.06, z + L * 0.065), L * 0.014, lantern, segments=8, rings=6)


def bird(p, center, s, color="bird"):
    x, y, z = center
    for side in (-1, 1):
        wing = [(0, 0), (side * 1.1 * s, 0.6 * s), (side * 2.3 * s, 0.35 * s), (side * 1.1 * s, 0.25 * s)]
        p.prism([(x + a, y + b) for a, b in wing], 0.2 * s, color, center=(0, 0, z))


def flock(p, center, s, r, count=5):
    x, y, z = center
    for _ in range(count):
        bird(p, (x + r.uniform(-8, 8) * s, y + r.uniform(-3, 3) * s, z + r.uniform(-4, 4) * s), s * r.uniform(0.7, 1.1))
