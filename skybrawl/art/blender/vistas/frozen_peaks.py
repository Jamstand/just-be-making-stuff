"""
FrozenPeaks background: an ice citadel under the aurora, on a clear blue
night. A pale stone-and-ice citadel with crystal spires, glowing windows and
a lit great gate crowns a snowy crag on the left, with a bridge down to an
outpost tower. Jagged snow-capped peaks rise on the right with a frozen
waterfall and giant glowing ice crystals at their feet. A big moon, stars
and aurora curtains fill the upper sky over a moonlit sea of clouds; snow
mist drifts along the bottom.
"""

import math
import random

from maps import _props_a as P
from vistas import _kit as K

MAP_ID = "FrozenPeaks"
SEED = 23

COLORS = {
    # snow and ice
    "snow": "#f4f8ff",
    "snow_shade": "#d6e3f6",
    "ice": "#9fe0f2",
    "ice_light": "#d6f6ff",
    "fall": "#bdeefc",
    "fall_light": "#effcff",
    # rock
    "rock_light": "#7fa0da",
    "rock": "#6384c5",
    "rock_dark": "#4b67a7",
    "far_rock": "#6f80c6",
    "far_snow": "#dfe7fb",
    # citadel
    "stone": "#e4ebfb",
    "stone_shade": "#b9c7ec",
    "roof": "#5f9fe8",
    "roof_violet": "#7a68d8",
    "roof_deep": "#3f55b8",
    "trim": "#f0cf78",
    "banner": "#d2467a",
    "banner_blue": "#3b56c9",
    "iron": "#2e3462",
    # glow
    "window": "#e7963a",
    "lantern": "#f2b24e",
    "crystal": "#4fd8f2",
    "crystal_violet": "#7a5ad8",
    "beacon": "#9ff6ff",
    "glint": "#cfefff",
    "star": "#dfe8ff",
    # life
    "pine": "#2f7569",
    "pine_dark": "#235b53",
    "trunk": "#6e4b3a",
    # clouds and mist
    "cloud": "#eef3ff",
    "cloud_far": "#dde5fa",
    "mist": "#e4ecff",
}

LOOK = {
    "dome": [(-0.3, "#2f3b88"), (-0.05, "#6a7ece"), (0.0, "#b4c4f2"), (0.04, "#97aaea"), (0.12, "#5c6dc6"),
             (0.22, "#38449e"), (0.34, "#242c78"), (0.46, "#161b52")],
    "sun": (0.46, 0.6),
    "sun_color": "#eef3ff",
    "sun_size": 6.0,
    "glow": "#7f93e8",
    "halo_size": 22.0,
    "halo_strength": 0.42,
    "light_dir": (0.72, 0.5, 0.38),
    "light": "#e2eaff",
    "mid": "#8696d2",
    "shadow": "#373b88",
    "cloud_light": "#d8e2fb",
    "cloud_mid": "#95a3dc",
    "cloud_shadow": "#555fb0",
    "rim": "#72d2ee",
    "ambient": "#3f4f92",
    "ink": "#10153a",
    "ink_soft": "#20275a",
    "fog_near": 800.0,
    "fog_far": 22000.0,
    "fog_max": 0.7,
    "sky_fog_scale": 1.6,
    "stars": 0.85,
    "aurora": [
        {"base": 0.235, "height": 0.13, "waves": 2.8, "phase": -1.99, "amp": 0.08, "rays": 36, "strength": 0.9},
        {"base": 0.4, "height": 0.1, "waves": 3.4, "phase": 1.2, "amp": 0.09, "rays": 24, "strength": 0.55},
    ],
    "aurora_colors": ["#4dffa0", "#2fe0c8", "#5a8bff", "#b070ff"],
    "glow_strength": 2.6,
}


def scene(v):
    r = K.rng(SEED)
    far(v, r)
    stars(v, r)
    citadel(v, r)
    peaks(v, r)
    middle(v, r)
    haze(v, r)


# Props ----------------------------------------------------------------------


def mountain(p, base, height, radius, r, rock="rock", snow="snow", snow_from=0.55, segments=9, depth=0.6,
             drip=0.14, lean=0.0, jag=0.2):
    """Faceted peak with a snow cap whose lower edge zigzags in drips. `lean`
    shifts the summit sideways by that fraction of the radius; `jag` roughens
    the spokes and rings."""
    bx, by, bz = base
    hs = [1.0, 0.82, 0.62, 0.42, 0.22, 0.0]
    rs = [0.0, 0.2, 0.42, 0.63, 0.83, 1.0]
    spokes = [1.0 + r.uniform(-jag, jag) for _ in range(segments)]
    noise = [[0.0] + [r.uniform(-jag, jag) * 0.45 for _ in hs[1:]] for _ in range(segments)]
    spin = math.radians(r.uniform(0, 360))

    def rad(k, hf):
        for i in range(len(hs) - 1):
            if hs[i + 1] <= hf <= hs[i]:
                t = (hs[i] - hf) / (hs[i] - hs[i + 1])
                a0 = rs[i] * (1 + noise[k][i])
                a1 = rs[i + 1] * (1 + noise[k][i + 1])
                return (a0 + (a1 - a0) * t) * radius * spokes[k]
        return radius * spokes[k]

    def pt(k, hf, grow=0.0):
        a = 2 * math.pi * k / segments + spin
        rr = rad(k, hf) * (1 + grow) + grow * radius * 0.03
        sx = lean * radius * hf
        return (bx + sx + math.cos(a) * rr, by + hf * height, bz + math.sin(a) * rr * depth)

    def skin(levels, color, grow, tip):
        verts = [(bx + lean * radius * tip, by + tip * height, bz)]
        rings = []
        for lv in levels:
            ring = []
            for k in range(segments):
                ring.append(len(verts))
                verts.append(pt(k, lv[k] if isinstance(lv, list) else lv, grow))
            rings.append(ring)
        faces = [(0, rings[0][k], rings[0][(k + 1) % segments]) for k in range(segments)]
        for r0, r1 in zip(rings, rings[1:]):
            for k in range(segments):
                j = (k + 1) % segments
                faces.append((r0[k], r0[j], r1[j], r1[k]))
        faces.append(tuple(reversed(rings[-1])))
        P.mesh(p, verts, faces, color)

    skin(hs[1:], rock, 0.0, 1.0)
    cut = 1.0 - snow_from
    edge = [cut - drip * r.uniform(0.5, 1.0) if k % 2 == 0 else cut + r.uniform(-0.02, 0.03)
            for k in range(segments)]
    upper = [hf for hf in hs[1:] if hf > cut + 0.06]
    skin(upper + [edge], snow, 0.05, 1.012)


def peak_group(p, v, u, top, d, wid, r, spurs=(), base_v=-0.95, **kw):
    """A mountain whose summit is at screen (u, top) at depth d, `wid` of the
    screen wide at its base, with smaller spur peaks fused into its flanks
    ((dx, height, width, dz) as fractions of the main one) for a jagged
    ridgeline."""
    tip = v.at(u, top, d)
    base_y = v.at(u, base_v, d)[1]
    height = tip[1] - base_y
    radius = wid * v.unit(d) * 0.5
    mountain(p, (tip[0], base_y, tip[2]), height, radius, r, **kw)
    for dx, hf, wf, dz in spurs:
        kw2 = dict(kw, lean=kw.get("lean", 0.0) + dx * 0.4)
        mountain(p, (tip[0] + dx * radius, base_y, tip[2] + dz * radius), height * hf, radius * wf, r, **kw2)


def spire(solid, glow, base, radius, height, wall="stone", roof="roof", roof_h=None, band="stone_shade",
          windows=2, segs=10, finial=None, flag=None):
    """Round citadel tower with a tall cone roof and lit slit windows.
    Returns the roof tip."""
    x, y, z = base
    solid.cylinder((x, y + height / 2, z), radius, height, wall, segments=segs)
    top = y + height
    solid.cylinder((x, top + radius * 0.14, z), radius * 1.18, radius * 0.28, band, segments=segs)
    rb = top + radius * 0.28
    rh = roof_h if roof_h is not None else radius * 3.4
    solid.cone((x, rb + rh / 2, z), radius * 1.3, rh, roof, segments=segs)
    for i in range(windows):
        wy = y + height * (0.35 + 0.55 * (i + 0.5) / windows)
        glow.box((x, wy, z + radius * 0.96), (radius * 0.28, radius * 0.62, radius * 0.12), "window", bevel=0)
    tip = (x, rb + rh, z)
    if finial:
        P.crystal(glow, (x, tip[1] - radius * 0.3, z), (x, tip[1] + radius * 1.4, z), radius * 0.26, finial)
    if flag:
        K.pennant(solid, (x, tip[1] + radius * 1.5, z), radius * 1.3, flag, pole="iron")
    return tip


def wall(solid, a, b, height, thick, color="stone", cap="snow"):
    """Straight battlement wall between base points a and b."""
    ax, ay, az = a
    bx, by, bz = b
    dx, dz = bx - ax, bz - az
    length = math.hypot(dx, dz)
    ang = math.degrees(math.atan2(-dz, dx))
    cx, cy, cz = (ax + bx) / 2, (ay + by) / 2, (az + bz) / 2
    solid.box((cx, cy + height / 2, cz), (length, height, thick), color, bevel=0, rotation=(0, ang, 0))
    n = max(2, int(length / (thick * 1.7)))
    for i in range(n):
        t = (i + 0.5) / n
        solid.box((ax + dx * t, cy + height + thick * 0.3, az + dz * t), (length / n * 0.55, thick * 0.6, thick * 1.05),
                  color, bevel=0, rotation=(0, ang, 0))
    solid.box((cx, cy + height + thick * 0.03, cz), (length * 1.01, thick * 0.12, thick * 1.25), cap, bevel=0,
              rotation=(0, ang, 0))


def banner(solid, top, length, width, color, emblem="trim"):
    """Hanging swallowtail banner with a rod and an emblem, facing the camera."""
    x, y, z = top
    w, L = width, length
    solid.prism([(-w / 2, 0), (w / 2, 0), (w / 2, -L), (0, -L * 0.8), (-w / 2, -L)], w * 0.06, color,
                center=(x, y, z))
    P.rod(solid, (x - w * 0.65, y, z), (x + w * 0.65, y, z), w * 0.06, "iron", segments=5)
    solid.prism([(0, -w * 0.25), (w * 0.2, -w * 0.5), (0, -w * 0.75), (-w * 0.2, -w * 0.5)], w * 0.05, emblem,
                center=(x, y - L * 0.25, z + w * 0.06))


def arch_bridge(solid, glow, a, b, width, thick, rise, spring, color="stone", rail="stone_shade", lamps=3):
    """Single-span stone arch bridge from deck point a to deck point b, seen
    from the side (extruded `width` toward the camera)."""
    ax, ay, az = a
    bx, by, bz = b
    n = 14
    top, bottom = [], []
    for i in range(n + 1):
        t = i / n
        x = ax + (bx - ax) * t
        y = ay + (by - ay) * t + rise * math.sin(math.pi * t)
        top.append((x, y))
        bottom.append((x, y - thick - spring * (1 - math.sin(math.pi * t)) ** 1.6))
    outline = top + list(reversed(bottom))
    z = (az + bz) / 2
    solid.prism(outline, width, color, center=(0, 0, z))
    for z_off in (-width * 0.42, width * 0.42):
        P.sweep(solid, [(x, y + thick * 0.35, z + z_off) for x, y in top],
                P.rect(thick * 0.18, thick * 0.18, width * 0.07, -width * 0.07), rail, up=(0, 0, 1))
    for k in range(lamps):
        i = int((k + 1) * n / (lamps + 1))
        x, y = top[i]
        P.rod(solid, (x, y, z + width * 0.45), (x, y + thick * 1.6, z + width * 0.45), thick * 0.08, "iron",
              segments=5)
        glow.sphere((x, y + thick * 1.75, z + width * 0.45), thick * 0.24, "lantern", segments=8, rings=6)


def pines_on(solid, v, spots, r):
    for u, sv, d, frac in spots:
        h = frac * v.unit(d) * r.uniform(0.85, 1.15)
        P.pine(solid, v.at(u, sv, d), h, "pine", "pine_dark", "snow", "trunk", tiers=3)


def glint(p, center, s, color="glint", waist=0.26, tilt=0.0):
    """Four-pointed sparkle facing the camera."""
    x, y, z = center
    pts = []
    for k in range(8):
        a = math.pi / 4 * k
        rr = s if k % 2 == 0 else s * waist
        pts.append((math.cos(a) * rr, math.sin(a) * rr))
    p.prism(pts, s * 0.1, color, center=(x, y, z), rotation=(0, 0, tilt))


def stars(v, r, count=60, sparkles=9):
    """Stars as small glowing dots and a few four-pointed sparkles in the
    upper sky, kept clear of the moon (the dome's own star field is finer
    than a pixel, so the brush filter wipes it out)."""
    glow = v.piece("Sky", "Glow")
    mu, mv = LOOK["sun"]
    placed = 0
    while placed < count + sparkles:
        u, sv = r.uniform(-1.1, 1.1), r.uniform(0.12, 1.08) ** 0.8
        if math.hypot((u - mu) * 1.78, sv - mv) < 0.42:
            continue
        d = 15000
        c = v.at(u, sv, d)
        if placed < sparkles:
            glint(glow, c, r.uniform(0.004, 0.0062) * v.unit(d), "star", waist=0.18, tilt=r.uniform(-8, 8))
        else:
            s = r.uniform(0.0011, 0.0022) * v.unit(d)
            glow.sphere(c, (s, s, s * 0.3), "star", segments=6, rings=4)
        placed += 1
    # one shooting star
    d = 15000
    head, tail = v.at(0.86, 0.9, d), v.at(0.66, 0.99, d)
    P.rod(glow, tail, head, 0.0002 * v.unit(d), "star", segments=5, radius_b=0.0016 * v.unit(d))
    glow.sphere(head, 0.0022 * v.unit(d), "star", segments=8, rings=5)


# Sky layer ------------------------------------------------------------------


def far(v, r):
    """A moonlit sea of clouds to the horizon, a long snowy range rising from
    it, and a few thin streaks of cloud by the moon."""
    clouds = v.piece("Sky", "Cloud")
    solid = v.piece("Sky", "Solid")
    for _ in range(60):
        d = r.uniform(4000, 24000)
        x = r.uniform(-1.25, 1.25) * d * v.tan_h
        K.cumulus(clouds, (x, -1250 + r.uniform(-200, 100), -d), r.uniform(0.2, 0.34) * v.unit(d) * 0.55,
                  "cloud_far", r, height=0.6, depth=0.7)
    # the far range, back row then a lower, nearer row
    for u, top, d, wid in ((-1.12, -0.04, 15000, 0.16), (-0.92, 0.07, 14000, 0.2), (-0.7, -0.06, 16000, 0.14),
                           (-0.48, 0.02, 15000, 0.17), (-0.26, -0.13, 17000, 0.12), (-0.06, -0.09, 16000, 0.15),
                           (0.16, -0.15, 17000, 0.12), (0.34, 0.0, 15000, 0.17), (0.56, 0.1, 14000, 0.2),
                           (0.8, -0.02, 16000, 0.15), (1.0, 0.06, 15000, 0.18), (1.18, -0.06, 16000, 0.14)):
        tip = v.at(u + r.uniform(-0.02, 0.02), top, d)
        base_y = -1500
        mountain(solid, (tip[0], base_y, tip[2]), tip[1] - base_y, wid * v.unit(d) * 0.5, r, rock="far_rock",
                 snow="far_snow", snow_from=0.5, segments=7, depth=0.5, lean=r.uniform(-0.15, 0.15), jag=0.25)
    for u, top, d, wid in ((-1.0, -0.14, 9000, 0.14), (-0.66, -0.17, 9500, 0.12), (0.64, -0.14, 9000, 0.14),
                           (1.04, -0.16, 9500, 0.12)):
        tip = v.at(u + r.uniform(-0.02, 0.02), top, d)
        base_y = -1300
        mountain(solid, (tip[0], base_y, tip[2]), tip[1] - base_y, wid * v.unit(d) * 0.5, r, rock="rock",
                 snow="far_snow", snow_from=0.45, segments=7, depth=0.5, lean=r.uniform(-0.2, 0.2), jag=0.25)
    for u, sv, d, length in ((0.28, 0.64, 9000, 0.14), (0.6, 0.55, 9500, 0.18), (0.76, 0.68, 8500, 0.1),
                             (-0.34, 0.84, 9000, 0.12), (-0.66, 0.7, 10000, 0.12)):
        for k in range(2):
            K.streak(clouds, v.at(u + (k - 0.5) * length * 0.6 + r.uniform(-0.02, 0.02),
                                  sv + r.uniform(-0.025, 0.025), d), length * r.uniform(0.6, 1.0) * v.unit(d),
                     "cloud_far", thickness=0.02)


# Landmarks ------------------------------------------------------------------

ISLE = ("snow", "snow_shade", "rock", "rock_dark")


def sky_rock(solid, glow, top, size, r, spikes=(), icicles=8, crystals=None, depth=0.8, band=True,
             hanging=()):
    """A broken-off mountaintop floating in the sky, like the stage itself:
    a thin snow cap with rounded drips over blue rock strata and a band of
    ice, a jagged underside with hanging spikes, icicles along the rim and
    glowing crystals under it. Its flat top is at `top`."""
    x, y, z = top
    S = size
    seg = 14
    seed = r.randrange(1 << 30)
    spin = r.uniform(0, 30)

    def layer(profile, color, jit=0.1, k=0, segments=seg):
        P.lathe(solid, (x, y, z), [(dy * S, rr * S) for dy, rr in profile], color, segments, jit,
                random.Random(seed + k), spin, depth)

    layer([(0.0, 0.47), (-0.02, 0.5), (-0.055, 0.5)], "snow", 0.06)
    layer([(-0.05, 0.49), (-0.12, 0.475)], "rock_light", 0.08, 1)
    if band:
        layer([(-0.115, 0.48), (-0.17, 0.47)], "ice", 0.06, 2)
        layer([(-0.165, 0.47), (-0.24, 0.45)], "rock_light", 0.08, 5)
    layer([(-0.235 if band else -0.115, 0.455), (-0.4, 0.38), (-0.62, 0.24), (-0.8, 0.12)], "rock", 0.14, 3, 10)
    layer([(-0.76, 0.14), (-1.02, 0.0)], "rock_dark", 0.15, 4, 7)
    # rounded snow drips along the front rim
    for i in range(13):
        a = math.radians(196 + 148 * (i + 0.5) / 13 + r.uniform(-3, 3))
        rr = S * r.uniform(0.028, 0.045)
        solid.sphere((x + math.cos(a) * S * 0.49, y - 0.045 * S, z - math.sin(a) * S * 0.49 * depth),
                     (rr * 1.3, rr * 0.8, rr), "snow", segments=8, rings=5)
    for fx, fz, ln, rad in spikes:
        P.lathe(solid, (x + fx * S, y - 0.3 * S, z + fz * S),
                [(0.0, rad * S), (-ln * 0.45 * S, rad * 0.72 * S), (-ln * S, 0.0)], "rock_dark", 6, 0.2,
                random.Random(r.randrange(1 << 30)), r.uniform(0, 60), 1.0)
    for k in range(icicles):
        a = math.radians(200 + 140 * (k + 0.5) / icicles + r.uniform(-5, 5))
        ln = S * r.uniform(0.05, 0.12)
        ix, iz = x + math.cos(a) * S * 0.46, z - math.sin(a) * S * 0.46 * depth
        solid.cone((ix, y - 0.2 * S - ln / 2, iz), S * 0.014, ln, "ice_light", rotation=(180, 0, 0), segments=5)
    for fx, ln, col in hanging:
        root = (x + fx * S, y - 0.27 * S, z + 0.37 * S * depth / 0.8)
        P.crystal(glow, root, (root[0] + fx * ln * S * 0.4, root[1] - ln * S, root[2] + 0.02 * S), S * 0.011,
                  col)
    if crystals:
        fx, fy, fz, cs, col = crystals
        P.crystal_cluster(glow, (x + fx * S, y + fy * S, z + fz * S), cs * S, col, r, count=4,
                          direction=(0.1, -1, 0.3), spread=30)


def icefall(solid, glow, r, x0, x1, y_top, z, length, radius):
    """A frozen waterfall as a curtain of fused icicle columns hanging from a
    rim, with lumps of frozen flow and a jagged bottom edge."""
    n = max(4, int((x1 - x0) / (radius * 1.5)))
    cols = ("fall", "fall_light", "ice", "fall", "ice_light")
    for i in range(n):
        t = i / (n - 1)
        x = x0 + (x1 - x0) * t + r.uniform(-0.2, 0.2) * radius
        mid = 1 - abs(t - 0.5) * 2
        ln = length * (0.55 + 0.45 * mid) * r.uniform(0.75, 1.05)
        rad = radius * (0.75 + 0.5 * mid) * r.uniform(0.85, 1.15)
        zz = z + r.uniform(-0.3, 0.3) * radius + mid * radius * 0.6
        body = ln * 0.78
        P.rod(solid, (x, y_top, zz), (x, y_top - body, zz), rad, cols[i % len(cols)], segments=7,
              radius_b=rad * 0.8)
        solid.cone((x, y_top - body - (ln - body) / 2, zz), rad * 0.8, ln - body, cols[i % len(cols)],
                   rotation=(180, 0, 0), segments=7)
        for k in range(2):
            ly = y_top - body * r.uniform(0.2, 0.8)
            solid.sphere((x, ly, zz + rad * 0.3), (rad * 1.15, rad * 1.6, rad * 1.05), cols[(i + 2) % len(cols)],
                         segments=8, rings=6)
    P.rod(glow, ((x0 + x1) / 2, y_top, z + radius * 1.5), ((x0 + x1) / 2, y_top - length * 0.7, z + radius * 1.5),
          radius * 0.18, "beacon", segments=5, radius_b=radius * 0.05)
    solid.sphere(((x0 + x1) / 2, y_top + radius * 0.2, z), ((x1 - x0) * 0.6, radius * 0.9, radius * 1.6), "snow",
                 segments=10, rings=6)


def citadel(v, r):
    """The ice citadel on its floating crag (left), a frozen waterfall
    spilling off its rim, and a bridge to an outpost tower."""
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    clouds = v.piece("Landmarks", "Cloud")
    d = 1700
    u0 = -0.66
    c = v.at(u0, -0.12, d)
    s = 0.35 * v.unit(d)  # the castle's scale
    S = 0.35 * v.unit(d)  # the rock's
    x, y, z = c
    sky_rock(solid, glow, c, S, r, spikes=((-0.3, 0.05, 0.6, 0.11), (0.27, 0.12, 0.5, 0.1), (-0.06, 0.2, 0.78, 0.12),
                                           (0.14, -0.08, 0.66, 0.1), (0.4, -0.02, 0.32, 0.07)),
             icicles=11,
             hanging=((-0.02, 0.2, "crystal"), (0.05, 0.28, "crystal"), (0.1, 0.16, "crystal_violet")))
    fall_len = v.at(u0, -0.12, d)[1] - v.at(u0, -0.95, d)[1]
    icefall(solid, glow, r, x + 0.17 * S, x + 0.33 * S, y - 0.03 * S, z + 0.33 * S, fall_len, 0.016 * S)

    # back row: glowing crystal spires
    P.crystal(glow, (x - 0.15 * s, y, z - 0.2 * s), (x - 0.17 * s, y + 0.5 * s, z - 0.2 * s), 0.035 * s,
              "crystal")
    P.crystal(glow, (x + 0.2 * s, y, z - 0.18 * s), (x + 0.22 * s, y + 0.42 * s, z - 0.18 * s), 0.03 * s,
              "crystal_violet")
    # towers, back to front
    spire(solid, glow, (x - 0.28 * s, y, z - 0.06 * s), 0.045 * s, 0.27 * s, roof="roof_violet",
          roof_h=0.15 * s, flag="banner")
    spire(solid, glow, (x + 0.31 * s, y, z - 0.04 * s), 0.05 * s, 0.29 * s, roof="roof", roof_h=0.16 * s,
          flag="banner_blue")
    spire(solid, glow, (x + 0.02 * s, y, z - 0.08 * s), 0.065 * s, 0.36 * s, roof="roof_deep", roof_h=0.21 * s,
          windows=3, finial="crystal")
    # the keep
    kx, kz = x - 0.03 * s, z + 0.03 * s
    kw, kh, kd = 0.32 * s, 0.2 * s, 0.16 * s
    solid.box((kx, y + kh / 2, kz), (kw, kh, kd), "stone", bevel=0)
    solid.wedge((kx, y + kh + 0.05 * s, kz), (kw * 1.06, 0.1 * s, kd * 1.12), "roof")
    solid.box((kx, y + kh + 0.004 * s, kz), (kw * 1.08, 0.012 * s, kd * 1.14), "stone_shade", bevel=0)
    for i in range(5):
        wx = kx + (i - 2) * kw * 0.19
        glow.box((wx, y + kh * 0.62, kz + kd / 2 + 0.003 * s), (0.022 * s, 0.05 * s, 0.006 * s), "window", bevel=0)
    # front wall, corner towers and the gatehouse
    wz = z + 0.22 * s
    wall(solid, (x - 0.42 * s, y, wz - 0.04 * s), (x - 0.09 * s, y, wz), 0.09 * s, 0.035 * s)
    wall(solid, (x + 0.09 * s, y, wz), (x + 0.42 * s, y, wz - 0.04 * s), 0.09 * s, 0.035 * s)
    for fx in (-0.42, 0.42):
        spire(solid, glow, (x + fx * s, y, wz - 0.04 * s), 0.045 * s, 0.15 * s, roof="roof_violet",
              roof_h=0.1 * s, windows=1)
    for fx in (-0.075, 0.075):
        spire(solid, glow, (x + fx * s, y, wz + 0.01 * s), 0.04 * s, 0.17 * s, roof="roof", roof_h=0.1 * s,
              windows=1, flag="banner" if fx < 0 else None)
    for fx in (-0.34, -0.2, 0.2, 0.34):
        P.rod(solid, (x + fx * s, y + 0.09 * s, wz + 0.02 * s), (x + fx * s, y + 0.125 * s, wz + 0.02 * s),
              0.003 * s, "iron", segments=4)
        glow.sphere((x + fx * s, y + 0.13 * s, wz + 0.02 * s), 0.008 * s, "lantern", segments=8, rings=6)
    for fx in (-0.26, 0.26):
        banner(solid, (x + fx * s, y + 0.085 * s, wz + 0.024 * s), 0.075 * s, 0.035 * s, "banner")
    gw, gh = 0.11 * s, 0.13 * s
    solid.box((x, y + gh / 2, wz), (gw, gh, 0.05 * s), "stone_shade", bevel=0)
    door = [(-gw * 0.3, 0)]
    for k in range(9):
        a = math.pi * k / 8
        door.append((-gw * 0.3 * math.cos(a), gh * 0.48 + gw * 0.3 * math.sin(a)))
    door.append((gw * 0.3, 0))
    glow.prism(door, 0.006 * s, "lantern", center=(x, y, wz + 0.027 * s))
    solid.box((x, y + gh + 0.01 * s, wz), (gw * 1.1, 0.02 * s, 0.055 * s), "snow", bevel=0)
    for fx, fz, h in ((0.47, 0.12, 0.08), (0.5, -0.05, 0.1), (-0.48, 0.1, 0.09)):
        P.pine(solid, (x + fx * S, y, z + fz * S), h * S, "pine", "pine_dark", "snow", "trunk", tiers=3)

    # the outpost rock and its bridge (at the left edge)
    oc = v.at(-1.14, -0.3, d)
    os_ = 0.12 * v.unit(d)
    sky_rock(solid, glow, oc, os_, r, spikes=((-0.15, 0.1, 0.5, 0.12), (0.2, 0.0, 0.4, 0.1)), icicles=4)
    spire(solid, glow, oc, os_ * 0.13, os_ * 0.62, roof="roof_violet", roof_h=os_ * 0.38, windows=2,
          flag="banner")
    arch_bridge(solid, glow, (x - 0.46 * S, y - 0.005 * S, z), (oc[0] + os_ * 0.35, oc[1], z),
                0.05 * s, 0.025 * s, 0.02 * s, 0.1 * s, lamps=2)
    for u, sv, dd, w in ((-0.42, -0.98, 1500, 0.2), (-0.8, -1.02, 1400, 0.22), (-1.1, -0.9, 1500, 0.2)):
        K.cumulus(clouds, v.at(u, sv, dd), w * v.unit(dd), "cloud", r, height=0.45)


def crystal_spray(solid, glow, base, size, r, glow_color="crystal", lean=0.0):
    """A fan of slim crystals from one root: the tall middle ones glow, pale
    solid ice shards around them."""
    bx, by, bz = base
    for ang, ln, lit in ((0, 1.0, True), (-24, 0.7, False), (21, 0.78, True), (-42, 0.5, True), (40, 0.55, False),
                         (9, 0.5, False), (-10, 0.62, False)):
        a = math.radians(ang + lean * 25 + r.uniform(-5, 5))
        L = size * ln * r.uniform(0.9, 1.1)
        dz = r.uniform(-0.05, 0.25)
        root = (bx + r.uniform(-0.06, 0.06) * size, by, bz + dz * size * 0.3)
        tip = (root[0] - math.sin(a) * L, by + math.cos(a) * L, root[2] + dz * L)
        if lit:
            P.crystal(glow, root, tip, L * 0.12, glow_color)
        else:
            P.crystal(solid, root, tip, L * 0.13, "ice_light" if ang > 0 else "ice")


def peaks(v, r):
    """Jagged snow-capped mountains on the right with snowy foothills,
    giant glowing ice crystals and pines."""
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    clouds = v.piece("Landmarks", "Cloud")
    for u, top, d, wid, lean, spurs in (
            (0.74, 0.44, 3000, 0.36, -0.1, ((-0.5, 0.6, 0.5, 0.2), (0.45, 0.68, 0.48, 0.15), (0.1, 0.4, 0.45, 0.4))),
            (0.55, 0.14, 3500, 0.2, 0.15, ((-0.4, 0.7, 0.5, 0.2),)),
            (1.06, 0.24, 2400, 0.3, 0.12, ((-0.45, 0.66, 0.5, 0.2), (0.4, 0.55, 0.5, 0.1))),
            (0.42, -0.06, 4400, 0.18, -0.1, ())):
        peak_group(solid, v, u, top, d, wid, r, spurs=spurs, segments=10, depth=0.55, lean=lean, snow_from=0.45,
                   jag=0.24)
    # foothills: small jagged peaks of dark rock, nearer and darker
    for u, top, d, wid, lean, spurs in ((0.5, -0.28, 1500, 0.15, 0.2, ((0.5, 0.6, 0.5, 0.2),)),
                                        (0.88, -0.16, 1450, 0.18, -0.1, ((-0.5, 0.62, 0.55, 0.25),)),
                                        (1.22, -0.24, 1500, 0.17, 0.1, ((0.45, 0.7, 0.5, 0.1),))):
        peak_group(solid, v, u, top, d, wid, r, spurs=spurs, base_v=-1.1, segments=8, depth=0.6, lean=lean,
                   snow_from=0.32, jag=0.28, drip=0.12, rock="rock_dark")
    for u, sv, dd, frac, col, lean in ((0.42, -0.5, 1250, 0.09, "crystal", 0.6),
                                       (0.95, -0.34, 1300, 0.08, "crystal_violet", -0.3),
                                       (0.78, -0.56, 1200, 0.05, "crystal", -0.2)):
        crystal_spray(solid, glow, v.at(u, sv, dd), frac * v.unit(dd), r, glow_color=col, lean=lean)
    pines_on(solid, v, ((0.58, -0.52, 1300, 0.04), (0.63, -0.58, 1250, 0.032), (0.95, -0.5, 1300, 0.045),
                        (1.0, -0.56, 1250, 0.036), (1.2, -0.48, 1300, 0.04), (0.34, -0.62, 1300, 0.03)), r)
    for u, sv, dd, w in ((0.42, -0.95, 1600, 0.2), (0.8, -1.0, 1500, 0.24), (1.14, -0.92, 1600, 0.22)):
        K.cumulus(clouds, v.at(u, sv, dd), w * v.unit(dd), "cloud", r, height=0.45)


def middle(v, r):
    """Small floating ice rocks in the middle distance."""
    solid = v.piece("Landmarks", "Solid")
    glow = v.piece("Landmarks", "Glow")
    for u, sv, d, frac, extra in ((0.12, 0.38, 4200, 0.05, "pine"), (-0.24, 0.6, 5000, 0.035, None),
                                  (1.0, 0.64, 3600, 0.05, "tower")):
        c = v.at(u, sv, d)
        s = frac * v.unit(d)
        sky_rock(solid, glow, c, s, r, spikes=((-0.1, 0.1, 0.5, 0.12),), icicles=4,
                 crystals=(0.05, -0.55, 0.2, 0.18, "crystal_violet") if extra != "pine" else None)
        if extra == "pine":
            P.pine(solid, (c[0] + s * 0.1, c[1], c[2]), s * 0.45, "pine", "pine_dark", "snow", "trunk", tiers=2)
        elif extra == "tower":
            spire(solid, glow, c, s * 0.08, s * 0.4, roof="roof_violet", roof_h=s * 0.25, windows=1)


# Haze -----------------------------------------------------------------------


def haze(v, r):
    """Snow mist drifting low along the bottom and a few glinting flakes."""
    clouds = v.piece("Haze", "Cloud")
    glow = v.piece("Haze", "Glow")
    us = [-1.34, -1.1, -0.86, -0.62, -0.38, -0.12, 0.14, 0.4, 0.66, 0.9, 1.14, 1.38]
    vs = [-0.8, -0.9, -1.0, -1.08, -1.14, -1.18, -1.18, -1.14, -1.08, -0.98, -0.88, -0.78]
    K.cloud_row(clouds, v, us, vs, 720, 0.18, "mist", r, height=0.5)
    K.cloud_row(clouds, v, [u + 0.12 for u in us[:-1]], [sv - 0.1 for sv in vs[:-1]], 560, 0.16, "mist", r,
                height=0.45)
    for u, sv, d, w in ((-1.15, -0.6, 800, 0.26), (1.15, -0.58, 820, 0.26)):
        K.streak(clouds, v.at(u, sv, d), w * v.unit(d), "mist", thickness=0.025, depth=0.05)
    for _ in range(22):
        u = r.choice((-1, 1)) * r.uniform(0.45, 1.3)
        sv = r.uniform(-0.55, 0.85)
        d = r.uniform(450, 900)
        s = r.uniform(0.0018, 0.0034) * v.unit(d)
        glint(glow, v.at(u, sv, d), s)
